import Foundation

// Reveal night logic, ported from reveal-logic.md (decided by Finley, Oct 17).
// Every screen runs the same pure function on the same frozen metadata and gets the same steps.
// The only live state is which step we're on, sent by the host.

/// One save, as the reveal sees it: metadata only, frozen at open. No names: `member` is opaque.
nonisolated struct RevealItem: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var member: String
    var kind: MomentKind
    var at: Date
    var text: String?
    var durationMs: Int?
    /// Who added it, shown on reveal night.
    var by: String = ""
    /// What they wrote under it, if anything.
    var caption: String?
}

nonisolated struct RevealCluster: Sendable {
    var index: Int
    var start: Date
    var end: Date
    var people: Int
    /// Position on the whole-chapter timeline, 0...1.
    var x: Double
    var isOverlap: Bool
    /// Every friend who saved anything is in it (and there are at least 2): the peak.
    var isEveryone: Bool
    /// Collages -> groups (pairs or singles) -> items.
    var parts: [[[RevealItem]]]
}

nonisolated enum RevealStep: Equatable, Sendable {
    case title
    case develop
    case open(cluster: Int, part: Int, peak: Bool)
    /// One moment from that section, full screen. (No longer compiled; kept so old setups decode.)
    case moment(cluster: Int, part: Int, index: Int)
    /// Everything from that section on one screen at once: a photo and a voice note from the same moment play together.
    case together(cluster: Int, part: Int)
    case interlude(from: Date, to: Date)
    case finale
    case end
}

nonisolated enum RevealCompiler {
    static let windowMs: TimeInterval = 30 * 60          // team decision
    static let pairCapMs: TimeInterval = 45 * 60         // a cluster may stretch this far, only to keep a pair whole
    static let echoMs: TimeInterval = 10 * 60            // Finley
    static let maxCollage = 9                            // tune on the TV
    static let interludeMs: TimeInterval = 2 * 60 * 60
    static let guessWho = false                          // Jackbox layer: off

    /// Run once at open, on the frozen metadata. Never re-run during the night.
    static func compile(_ items: [RevealItem], opensAt: Date, sealAt: Date) -> (clusters: [RevealCluster], steps: [RevealStep]) {
        let sorted = items.sorted { $0.at == $1.at ? $0.id.uuidString < $1.id.uuidString : $0.at < $1.at }
        let friends = Set(sorted.map(\.member)).count
        let span = max(sealAt.timeIntervalSince(opensAt), 1)

        let clusters = groupIntoWindows(sorted).enumerated().map { index, items -> RevealCluster in
            let people = Set(items.map(\.member)).count
            let start = items.first!.at, end = items.last!.at
            return RevealCluster(
                index: index, start: start, end: end, people: people,
                x: min(max(start.timeIntervalSince(opensAt) / span, 0), 1),
                isOverlap: people > 1,
                isEveryone: friends > 1 && people == friends,
                parts: splitCollage(findEchoes(items), max: maxCollage)
            )
        }

        var steps: [RevealStep] = [.title, .develop]
        for (i, c) in clusters.enumerated() {
            if i > 0, c.start.timeIntervalSince(clusters[i - 1].end) > interludeMs {
                steps.append(.interlude(from: clusters[i - 1].end, to: c.start))
            }
            for part in c.parts.indices {
                steps.append(.open(cluster: c.index, part: part, peak: c.isEveryone))
                steps.append(.together(cluster: c.index, part: part))
            }
        }
        steps.append(contentsOf: [.finale, .end])
        return (clusters, steps)
    }

    /// Clusters anchored 30 minutes from their first save; a pair (different friends within 10 min)
    /// may stretch the cluster up to 45 minutes so it isn't split.
    static func groupIntoWindows(_ sorted: [RevealItem]) -> [[RevealItem]] {
        var out: [[RevealItem]] = []
        var start = Date.distantPast
        for c in sorted {
            let last = out.last?.last
            let inWindow = c.at.timeIntervalSince(start) <= windowMs
            let keepsPair = last.map { $0.member != c.member && c.at.timeIntervalSince($0.at) <= echoMs && c.at.timeIntervalSince(start) <= pairCapMs } ?? false
            if !out.isEmpty, inWindow || keepsPair {
                out[out.count - 1].append(c)
            } else {
                out.append([c])
                start = c.at
            }
        }
        return out
    }

    /// Runs chained within 10 minutes; a run with 2+ friends is a pair (echo), otherwise singles.
    static func findEchoes(_ items: [RevealItem]) -> [[RevealItem]] {
        var runs: [[RevealItem]] = []
        for c in items {
            if let last = runs.last?.last, c.at.timeIntervalSince(last.at) <= echoMs {
                runs[runs.count - 1].append(c)
            } else {
                runs.append([c])
            }
        }
        return runs.flatMap { run in Set(run.map(\.member)).count > 1 ? [run] : run.map { [$0] } }
    }

    /// Collages of <= max items, split evenly, pairs kept whole unless a pair alone is bigger than max.
    static func splitCollage(_ groups: [[RevealItem]], max: Int) -> [[[RevealItem]]] {
        let pieces = groups.flatMap { $0.count <= max ? [$0] : chunk($0, max: max) }
        let total = pieces.reduce(0) { $0 + $1.count }
        if total <= max { return [pieces] }
        let target = Int((Double(total) / ceil(Double(total) / Double(max))).rounded(.up))
        var out: [[[RevealItem]]] = [[]]
        var n = 0
        for g in pieces {
            if n > 0, n + g.count > target { out.append([]); n = 0 }
            out[out.count - 1].append(g)
            n += g.count
        }
        return out
    }

    static func chunk<T>(_ arr: [T], max: Int) -> [[T]] {
        let k = Int(ceil(Double(arr.count) / Double(max)))
        let size = Int(ceil(Double(arr.count) / Double(k)))
        return (0..<k).map { i in Array(arr[min(i * size, arr.count)..<min((i + 1) * size, arr.count)]) }
    }

    // MARK: Title card

    static func counts(_ items: [RevealItem]) -> String {
        let labels: [(MomentKind, String, String)] = [
            (.photo, "photo", "photos"), (.voice, "voice note", "voice notes"), (.doodle, "doodle", "doodles"),
            (.video, "video", "videos"), (.word, "words", "words"),
        ]
        return labels.compactMap { kind, one, many in
            let n = items.filter { $0.kind == kind || (kind == .word && $0.kind == .note) }.count
            return n > 0 ? "\(n) \(n == 1 ? one : many)" : nil
        }
        .joined(separator: " · ")
    }

    /// Same day: "Oct 18 · 2026". Same year: "Oct 18 – Oct 25 · 2026". Across years: "Oct 18 · 2026 – Oct 18 · 2027".
    static func dateRange(_ from: Date, _ to: Date) -> String {
        let cal = Calendar.current
        let md: (Date) -> String = { $0.formatted(.dateTime.month(.abbreviated).day()) }
        let y: (Date) -> String = { $0.formatted(.dateTime.year()) }
        if cal.isDate(from, inSameDayAs: to) { return "\(md(from)) · \(y(from))" }
        if cal.component(.year, from: from) == cal.component(.year, from: to) { return "\(md(from)) – \(md(to)) · \(y(from))" }
        return "\(md(from)) · \(y(from)) – \(md(to)) · \(y(to))"
    }

    /// Title card: always start to end, so the room sees how long it ran.
    /// Same day: "Oct 18 · 9:02 am – 8:40 pm". Same year: "Oct 12 – Oct 18 · 2026". Across years: "Oct 18 · 2026 – Oct 18 · 2027".
    static func span(_ from: Date, _ to: Date) -> String {
        let cal = Calendar.current
        let md: (Date) -> String = { $0.formatted(.dateTime.month(.abbreviated).day()) }
        let y: (Date) -> String = { $0.formatted(.dateTime.year()) }
        if cal.isDate(from, inSameDayAs: to) { return "\(md(from)) · \(time(from)) – \(time(to))" }
        if cal.component(.year, from: from) == cal.component(.year, from: to) { return "\(md(from)) – \(md(to)) · \(y(from))" }
        return "\(md(from)) · \(y(from)) – \(md(to)) · \(y(to))"
    }

    /// "Saturday night". Late night counts toward the evening before.
    static func section(_ date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let day = hour < 4 ? date.addingTimeInterval(-6 * 3600) : date
        let part = switch hour {
        case 4..<12: "morning"
        case 12..<17: "afternoon"
        case 17..<21: "evening"
        default: "night"
        }
        return "\(day.formatted(.dateTime.weekday(.wide))) \(part)"
    }

    /// "SAT 9:48"
    static func stamp(_ date: Date) -> String {
        "\(date.formatted(.dateTime.weekday(.abbreviated))) \(date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))"
    }

    /// "3:06 pm"
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute()).lowercased()
    }

    /// Timeline ends: just the time within one day, the date too across days.
    static func edge(_ date: Date, spanning other: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: other)
            ? time(date)
            : "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time(date))"
    }

    /// Frozen metadata for a roll. Grouping uses opaque ids; `by` carries the name for display.
    static func items(for roll: Roll) -> [RevealItem] {
        var ids: [String: String] = [:]
        return roll.moments.map { m in
            let member = ids[m.author] ?? { let id = "m\(ids.count + 1)"; ids[m.author] = id; return id }()
            return RevealItem(id: m.id, member: member, kind: m.kind, at: m.createdAt,
                              text: (m.kind == .word || m.kind == .note) ? m.text : nil, durationMs: nil, by: m.author,
                              caption: m.caption.isEmpty ? nil : m.caption)
        }
    }
}
