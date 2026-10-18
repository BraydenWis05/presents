import Foundation

nonisolated enum MomentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case photo, video, voice, doodle, word, note

    var id: String { rawValue }

    /// What the roll can pick at capture. Notes only exist as sample stand-ins.
    static let capturable: [MomentKind] = [.photo, .video, .voice, .doodle, .word]

    var title: String {
        switch self {
        case .photo: "Photo"
        case .video: "Video"
        case .voice: "Voice note"
        case .doodle: "Doodle"
        case .word: "Words"
        case .note: "Note"
        }
    }

    var symbol: String {
        switch self {
        case .photo: "camera"
        case .video: "video"
        case .voice: "waveform"
        case .doodle: "scribble"
        case .word: "textformat"
        case .note: "text.alignleft"
        }
    }

    /// What the roll asks for once it lands on this format.
    var invitation: String {
        switch self {
        case .photo: "Snap whatever's in front of you."
        case .video: "Film a few seconds of it."
        case .voice: "Say it out loud."
        case .doodle: "Draw it. Badly is fine."
        case .word: "Say it in a few words."
        case .note: "Write it down, quick."
        }
    }

    /// The button that starts capturing once it's picked.
    var action: String {
        switch self {
        case .photo: "Snap"
        case .video: "Film"
        case .voice: "Record"
        case .doodle: "Draw"
        case .word: "Write"
        case .note: "Write"
        }
    }
}

struct Reflection: Codable, Identifiable, Hashable {
    var id = UUID()
    var author: String
    var text: String
    var createdAt = Date()
}

struct Moment: Codable, Identifiable, Hashable {
    var id = UUID()
    var author: String
    var kind: MomentKind
    var caption: String = ""
    /// Body text for notes.
    var text: String = ""
    /// File name inside the media folder, for photos and voice memos.
    var mediaFile: String?
    var prompt: String?
    var createdAt = Date()
    var reflections: [Reflection] = []
    /// Emoji → who reacted. Only after the reveal. Optional so older saves still load.
    var reactions: [String: [String]]?
    /// Hidden during the reveal by someone in the room. Stays sealed in the archive.
    var hiddenAt: Date?

    static let reactionChoices = ["🔥", "💯", "❤️", "😂", "🥹", "👏"]

    var reactionCounts: [(emoji: String, count: Int)] {
        (reactions ?? [:])
            .map { (emoji: $0.key, count: $0.value.count) }
            .filter { $0.count > 0 }
            .sorted { $0.count == $1.count ? $0.emoji < $1.emoji : $0.count > $1.count }
    }

    var reactionTotal: Int { (reactions ?? [:]).values.reduce(0) { $0 + $1.count } }
}

struct Roll: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var members: [String]
    var revealDate: Date
    var createdAt = Date()
    var moments: [Moment] = []
    var revealedAt: Date?

    var isRevealed: Bool { revealedAt != nil }
    var isReadyToOpen: Bool { Date() >= revealDate }

    var daysToReveal: Int {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: revealDate)).day ?? 0
        return max(days, 0)
    }

    /// How full the orb looks, 0...1. Purely overall, never per person.
    var fill: Double { min(Double(moments.count) / 27.0, 1) }

    var revealOrder: [Moment] { moments.sorted { $0.createdAt < $1.createdAt } }
}

enum GroupRules {
    /// Placeholder until research sets the real cap (spec: "decide before screens").
    static let maxSize = 8
}

struct CaptureRequest: Identifiable {
    var id = UUID()
    /// Friends nearby when this came from the "document this?" nudge.
    var with: [String] = []
}
