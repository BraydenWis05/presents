import SwiftUI
import UIKit
import AVFoundation

// MARK: Orientation

/// The app is portrait; the reveal turns sideways for the TV.
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = .portrait

    static func set(_ new: UIInterfaceOrientationMask) {
        mask = new
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: new)) { _ in }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

// MARK: Sound (reveal-logic.md §4)

/// What the room hears. Only the TV (host) plays sound.
/// On open: videos muted and looping, voice notes one after another, then each video's audio in turn.
@Observable
final class RevealSound {
    @ObservationIgnored private var videoPlayers: [UUID: AVPlayer] = [:]
    @ObservationIgnored private var voice: AVPlayer?
    @ObservationIgnored private var queue: [(id: UUID, isVideo: Bool, url: URL)] = []
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var loopObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var chorusTask: Task<Void, Never>?
    private(set) var playing: UUID?

    func player(for id: UUID, url: URL) -> AVPlayer {
        if let p = videoPlayers[id] { return p }
        let p = AVPlayer(url: url)
        p.isMuted = true
        p.actionAtItemEnd = .none
        let token = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: p.currentItem, queue: .main) { [weak p] _ in
            MainActor.assumeIsolated {
                // Muted videos loop; the one whose turn it is is handled by the queue.
                guard let p, p.isMuted else { return }
                p.seek(to: .zero)
                p.play()
            }
        }
        loopObservers.append(token)
        videoPlayers[id] = p
        p.play()
        return p
    }

    /// Start a collage's sound. `delay` holds a beat (longer for the peak).
    func start(voices: [(UUID, URL)], videos: [(UUID, URL)], delay: Double) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        for (id, url) in videos { _ = player(for: id, url: url) }
        queue = voices.map { ($0.0, false, $0.1) } + videos.map { ($0.0, true, $0.1) }
        startTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            playNext()
        }
    }

    /// A hidden item: its sound stops, the rest carries on.
    func skip(_ id: UUID) {
        queue.removeAll { $0.id == id }
        videoPlayers[id]?.pause()
        if playing == id { finishCurrent(); playNext() }
    }

    func pauseAll() {
        startTask?.cancel()
        if let voice { fadeOut(voice) }
        for p in videoPlayers.values { p.isMuted = true; p.pause() }
    }

    func resumeAll() {
        for p in videoPlayers.values { p.play() }
        if let voice { voice.volume = 1; voice.play() } else if playing == nil { playNext() }
    }

    func stop() {
        startTask?.cancel()
        chorusTask?.cancel()
        voice?.pause()
        voice = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        for t in loopObservers { NotificationCenter.default.removeObserver(t) }
        loopObservers = []
        for p in videoPlayers.values { p.pause() }
        videoPlayers = [:]
        queue = []
        playing = nil
    }

    private func playNext() {
        guard !queue.isEmpty else { playing = nil; return }
        let next = queue.removeFirst()
        playing = next.id
        let item: AVPlayerItem?
        if next.isVideo, let p = videoPlayers[next.id] {
            p.isMuted = false
            p.seek(to: .zero)
            p.play()
            item = p.currentItem
        } else {
            let p = AVPlayer(url: next.url)
            voice = p
            p.play()
            item = p.currentItem
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finishCurrent()
                self?.playNext()
            }
        }
    }

    private func finishCurrent() {
        if let id = playing, let p = videoPlayers[id] {
            p.isMuted = true
            p.seek(to: .zero)
            p.play()
        }
        voice?.pause()
        voice = nil
    }

    private func fadeOut(_ player: AVPlayer) {
        Task {
            for v in stride(from: 1.0, through: 0, by: -0.25) {
                player.volume = Float(v)
                try? await Task.sleep(for: .milliseconds(100))
            }
            player.pause()
        }
    }

    /// Finale chorus (§7): up to 3 s of each voice note and video, in order, short crossfades, about 30 s max.
    func chorus(_ clips: [URL]) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        chorusTask = Task {
            for url in clips.prefix(10) {
                guard !Task.isCancelled else { return }
                let p = AVPlayer(url: url)
                p.volume = 0
                voice = p
                p.play()
                for v in stride(from: 0.0, through: 1, by: 0.25) { p.volume = Float(v); try? await Task.sleep(for: .milliseconds(75)) }
                try? await Task.sleep(for: .milliseconds(2400))
                for v in stride(from: 1.0, through: 0, by: -0.25) { p.volume = Float(v); try? await Task.sleep(for: .milliseconds(75)) }
                p.pause()
            }
        }
    }
}

// MARK: The TV

/// Reveal night on the TV (or a phone turned sideways). The host taps; nothing auto-advances except interludes.
struct PresentationNight: View {
    var roll: Roll
    var onFinish: () -> Void

    @Environment(RollStore.self) private var store
    @Environment(NightRoom.self) private var room
    @State private var sound = RevealSound()

    private var step: RevealStep { room.steps.indices.contains(room.step) ? room.steps[room.step] : .title }
    private var items: [RevealItem] { room.setup?.items ?? [] }
    private var opensAt: Date { room.setup?.opensAt ?? .now }
    private var sealAt: Date { room.setup?.sealAt ?? .now }

    var body: some View {
        ZStack {
            Palette.backgroundBottom.ignoresSafeArea()
            GrainOverlay().opacity(0.7).ignoresSafeArea()

            Group {
                switch step {
                case .title:
                    TitleCard(title: roll.name, items: items, opensAt: opensAt, sealAt: sealAt, inRoom: room.inRoom)
                case .develop:
                    DevelopScene(clusters: room.clusters, opensAt: opensAt, sealAt: sealAt)
                case .open(let c, let part, _):
                    SectionScene(items: room.clusters[c].parts[part].flatMap { $0 }, hidden: room.hidden)
                case .together(let c, let part):
                    CollageScene(groups: room.clusters[c].parts[part], peak: room.clusters[c].isEveryone, hidden: room.hidden, paused: room.paused, sound: sound)
                case .moment(let c, let part, let i):
                    MomentReveal(item: room.clusters[c].parts[part].flatMap { $0 }[i], hidden: room.hidden, paused: room.paused, sound: sound)
                case .interlude(let from, let to):
                    InterludeCard(from: from, to: to)
                case .finale, .end:
                    FinaleWall(items: items, opensAt: opensAt, sealAt: sealAt, hidden: room.hidden, showsEnd: step == .end, onDone: finish)
                }
            }
            .id(room.step)
            .transition(.opacity)

            if room.paused {
                VStack(spacing: 8) {
                    Text("Paused").font(.display(36)).foregroundStyle(Palette.ink)
                    Text("Tap to carry on when the room's ready").font(.copy(13)).foregroundStyle(Palette.secondary)
                }
                .transition(.opacity)
            }

            controls
        }
        .animation(.easeInOut(duration: 0.6), value: room.paused)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .global) { location in
            if room.paused { room.hostResume(); return }
            location.x < UIScreen.main.bounds.width * 0.2 ? back() : advance()
        }
        .onAppear {
            OrientationLock.set(.landscape)
            // Compile once, at open, from metadata only.
            room.host(NightRoom.Setup(
                rollID: roll.id, title: roll.name,
                // The timeline always spans every save, even if dates were moved.
                opensAt: min(roll.createdAt, roll.moments.map(\.createdAt).min() ?? roll.createdAt),
                sealAt: max(roll.revealedAt ?? roll.revealDate, roll.moments.map(\.createdAt).max() ?? roll.revealDate),
                items: RevealCompiler.items(for: roll),
                hidden: roll.moments.filter { $0.hiddenAt != nil }.map(\.id)
            ), me: store.state.me)
            room.onHide = { id in
                store.hideMoment(id, in: roll.id)
                sound.skip(id)
            }
        }
        .onDisappear {
            sound.stop()
            room.stop()
            OrientationLock.set(.portrait)
        }
        .onChange(of: room.step) { stage() }
        .onChange(of: room.paused) { _, paused in paused ? sound.pauseAll() : sound.resumeAll() }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
    }

    private var controls: some View {
        VStack {
            HStack(spacing: 12) {
                Button { finish() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink.opacity(0.6))
                        .frame(width: 36, height: 36)
                }
                Spacer()
                AirPlayButton().frame(width: 36, height: 36).opacity(0.6)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            Spacer()
        }
    }

    private func advance() { withAnimation(.easeInOut(duration: 0.8)) { room.go(to: room.step + 1) } }
    private func back() { withAnimation(.easeInOut(duration: 0.5)) { room.go(to: room.step - 1) } }

    private func stage() {
        switch step {
        case .together(let c, let part):
            let flat = room.clusters[c].parts[part].flatMap { $0 }.filter { !room.hidden.contains($0.id) }
            let voices = flat.filter { $0.kind == .voice }.compactMap { i in url(i.id).map { (i.id, $0) } }
            let videos = flat.filter { $0.kind == .video }.compactMap { i in url(i.id).map { (i.id, $0) } }
            sound.start(voices: voices, videos: videos, delay: 1.2)
        case .moment(let c, let part, let i):
            let one = room.clusters[c].parts[part].flatMap { $0 }[i]
            let flat = room.hidden.contains(one.id) ? [] : [one]
            let peak = false
            let voices = flat.filter { $0.kind == .voice }.compactMap { i in url(i.id).map { (i.id, $0) } }
            let videos = flat.filter { $0.kind == .video }.compactMap { i in url(i.id).map { (i.id, $0) } }
            sound.start(voices: voices, videos: videos, delay: peak ? 1.8 : 0.6)
        case .interlude:
            sound.stop()
            // Only the host's screen auto-advances interludes.
            let at = room.step
            Task {
                try? await Task.sleep(for: .seconds(2))
                if room.step == at { advance() }
            }
        case .finale:
            let clips = items.filter { ($0.kind == .voice || $0.kind == .video) && !room.hidden.contains($0.id) }
                .sorted { $0.at < $1.at }
                .compactMap { url($0.id) }
            sound.chorus(clips)
        default:
            sound.stop()
        }
    }

    private func url(_ id: UUID) -> URL? {
        guard let m = roll.moments.first(where: { $0.id == id }), let url = store.mediaURL(m),
              FileManager.default.fileExists(atPath: url.path()) else { return nil }
        return url
    }

    private func finish() {
        sound.stop()
        room.stop()
        OrientationLock.set(.portrait)
        onFinish()
    }
}

// MARK: Frames

/// One saved thing as a frame. Media this phone doesn't have (or that failed) renders as a soft blur.
struct RevealFrame: View {
    var item: RevealItem
    var sharp: Bool
    var hidden: Bool
    var sound: RevealSound?
    @Environment(RollStore.self) private var store

    private var moment: Moment? { store.state.rolls.lazy.flatMap(\.moments).first { $0.id == item.id } }
    private var hasMedia: Bool {
        guard let moment else { return false }
        if item.kind == .voice { return store.mediaURL(moment) != nil }
        return store.image(for: moment) != nil || item.kind == .video
    }

    var body: some View {
        ZStack {
            item.kind.orbColor.opacity(0.5)
            GrainOverlay().opacity(0.9)
            if !hidden, let moment {
                switch item.kind {
                case .photo, .doodle:
                    if let image = store.image(for: moment) { Image(uiImage: image).resizable().scaledToFill() }
                case .video:
                    if let sound, let url = store.mediaURL(moment) {
                        PlayerLayer(player: sound.player(for: item.id, url: url))
                    } else if let image = store.image(for: moment) {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                case .voice:
                    Image(systemName: "waveform")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Palette.ink.opacity(sound?.playing == item.id ? 1 : 0.6))
                        .symbolEffect(.variableColor.iterative, isActive: sound?.playing == item.id)
                case .word, .note:
                    EmptyView()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .blur(radius: hidden ? 28 : (sharp && hasMedia ? 0 : 24))
        .scaleEffect(hidden ? 0.85 : 1)
        .opacity(hidden ? 0.45 : 1)
        .animation(.easeOut(duration: 1.4), value: sharp)
        .animation(.easeInOut(duration: 0.6), value: hidden)
    }
}

/// Plain AVPlayerLayer, no controls.
struct PlayerLayer: UIViewRepresentable {
    var player: AVPlayer
    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PlayerView, context: Context) { uiView.playerLayer.player = player }
    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

// MARK: Steps

/// Title card / lobby: chapter title, the dates it ran, a count of each media type, who's in the room.
private struct TitleCard: View {
    var title: String
    var items: [RevealItem]
    var opensAt: Date
    var sealAt: Date
    var inRoom: [String]

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.display(56)).foregroundStyle(Palette.ink)
            Text(RevealCompiler.dateRange(opensAt, sealAt)).font(.display(20)).foregroundStyle(Palette.secondary)
            Text(RevealCompiler.counts(items)).font(.copy(14)).foregroundStyle(Palette.ink.opacity(0.8)).padding(.top, 6)
            VStack(spacing: 6) {
                if inRoom.isEmpty {
                    Text("Friends: open Presents to join").font(.copy(12)).foregroundStyle(Palette.secondary)
                } else {
                    HStack(spacing: -6) { ForEach(inRoom, id: \.self) { Avatar(name: $0, size: 28) } }
                    Text("\(inRoom.count) in the room").font(.copy(12)).foregroundStyle(Palette.secondary)
                }
            }
            .padding(.top, 18)
        }
    }
}

/// The sealed roll develops into soft blobs on the whole-chapter timeline. Bigger blob = more people.
private struct DevelopScene: View {
    var clusters: [RevealCluster]
    var opensAt: Date
    var sealAt: Date
    @State private var shown = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 120
            let y = geo.size.height * 0.55
            ZStack {
                Rectangle().fill(Palette.ink.opacity(0.15)).frame(width: w, height: 1)
                    .position(x: geo.size.width / 2, y: y)
                ForEach(clusters, id: \.index) { c in
                    let size = 40 + CGFloat(c.people) * 22
                    let kinds = c.parts.flatMap { $0.flatMap { $0 } }.map(\.kind)
                    Circle()
                        .fill(AngularGradient(colors: kinds.map(\.orbColor) + [kinds.first?.orbColor ?? .gray], center: .center))
                        .frame(width: size, height: size)
                        .blur(radius: 14)
                        .opacity(shown ? 0.9 : 0)
                        .scaleEffect(shown ? 1 : 0.4)
                        .position(x: 60 + c.x * w, y: y)
                        .animation(.easeOut(duration: 1.2).delay(Double(c.index) * 0.12), value: shown)
                }
                HStack {
                    Text(RevealCompiler.edge(opensAt, spanning: sealAt)).font(.copy(11)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Text(RevealCompiler.edge(sealAt, spanning: opensAt)).font(.copy(11)).foregroundStyle(Palette.secondary)
                }
                .frame(width: w)
                .position(x: geo.size.width / 2, y: y + 70)
            }
        }
        .onAppear { shown = true }
    }
}

/// One cluster (or half of a big one), everything revealed at once. Time labels only, no names.
private struct CollageScene: View {
    var groups: [[RevealItem]]
    var peak: Bool
    var hidden: Set<UUID>
    var paused: Bool
    var sound: RevealSound
    @State private var sharp = false
    @State private var lineIndex = 0

    private var flat: [RevealItem] { groups.flatMap { $0 } }
    private var pictures: [RevealItem] { flat.filter { $0.kind != .word && $0.kind != .note } }
    private var lines: [RevealItem] { flat.filter { ($0.kind == .word || $0.kind == .note) && !hidden.contains($0.id) } }

    var body: some View {
        GeometryReader { geo in
            let scale: CGFloat = peak ? 1 : 0.86
            VStack(spacing: 14) {
                Text(timeLabel).font(.display(18)).foregroundStyle(Palette.ink.opacity(0.85))
                    .padding(.top, 18)
                collage(in: CGSize(width: geo.size.width * 0.86 * scale,
                                   height: geo.size.height * (lines.isEmpty ? 0.72 : 0.6) * scale))
                if !lines.isEmpty {
                    let line = lines[min(lineIndex, lines.count - 1)]
                    Text("— \(line.by)").font(.copy(13)).foregroundStyle(Palette.secondary)
                        .opacity(sharp && !paused ? 1 : 0)
                    Text(line.text ?? "")
                        .font(.display(30))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                        .id(lineIndex)
                        .transition(.opacity)
                        .opacity(sharp && !paused ? 1 : 0)
                        .padding(.horizontal, 60)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            Task {
                try? await Task.sleep(for: .seconds(peak ? 1.2 : 0.2))
                sharp = true
                // Typed lines: one at a time, in time order.
                for i in lines.indices.dropFirst() {
                    try? await Task.sleep(for: .seconds(3.5))
                    withAnimation(.easeInOut(duration: 0.6)) { lineIndex = i }
                }
            }
        }
    }

    private var timeLabel: String {
        guard let first = flat.first?.at, let last = flat.last?.at else { return "" }
        let a = RevealCompiler.time(first), b = RevealCompiler.time(last)
        return a == b ? a : "\(a) – \(b)"
    }

    @ViewBuilder private func collage(in size: CGSize) -> some View {
        let n = max(pictures.count, 1)
        let cols = n <= 1 ? 1 : (n <= 4 ? 2 : 3)
        let rows = Int(ceil(Double(n) / Double(cols)))
        let spacing: CGFloat = 10
        let cellW = (size.width - CGFloat(cols - 1) * spacing) / CGFloat(cols)
        let cellH = (size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
        if pictures.isEmpty {
            Color.clear.frame(width: size.width, height: size.height * 0.3)
        } else {
            VStack(spacing: spacing) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: spacing) {
                        ForEach(pictures.indices.filter { $0 / cols == r }, id: \.self) { i in
                            let item = pictures[i]
                            RevealFrame(item: item, sharp: sharp && !paused, hidden: hidden.contains(item.id), sound: sound)
                                .frame(width: cellW, height: cellH)
                                .overlay(alignment: .bottomLeading) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        if let caption = item.caption, !hidden.contains(item.id) {
                                            Text(caption)
                                                .font(.displayItalic(18))
                                                .foregroundStyle(.white)
                                                .shadow(color: .black.opacity(0.7), radius: 8)
                                                .opacity(sharp && !paused ? 1 : 0)
                                        }
                                        HStack(spacing: 6) {
                                            Avatar(name: item.by, size: 20)
                                            Text("\(item.by) · \(RevealCompiler.time(item.at))")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(.white)
                                        }
                                        .padding(.horizontal, 6).padding(.vertical, 4)
                                        .background(Capsule().fill(.black.opacity(0.45)))
                                    }
                                    .padding(8)
                                }
                        }
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

/// A gap of more than 2 hours between clusters gets a quiet card.
private struct InterludeCard: View {
    var from: Date
    var to: Date
    var body: some View {
        Text("\(RevealCompiler.time(from)) → \(RevealCompiler.time(to))")
            .font(.displayItalic(34))
            .foregroundStyle(Palette.secondary)
    }
}

/// The whole chapter on one wall: every frame back at its spot on the timeline, pairs stacked,
/// typed lines floating over their stretch. Then it stays as the archive.
private struct FinaleWall: View {
    var items: [RevealItem]
    var opensAt: Date
    var sealAt: Date
    var hidden: Set<UUID>
    var showsEnd: Bool
    var onDone: () -> Void
    @State private var settled = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 140
            let span = max(sealAt.timeIntervalSince(opensAt), 1)
            let lineY = geo.size.height * 0.72
            let rows = max(1, Int((lineY - 40) / 62))
            ZStack {
                Rectangle().fill(Palette.ink.opacity(0.15)).frame(width: w, height: 1)
                    .position(x: geo.size.width / 2, y: lineY)
                ForEach(layout(width: w), id: \.item.id) { p in
                    let x = 70 + CGFloat(p.item.at.timeIntervalSince(opensAt) / span) * w
                    Group {
                        if p.item.kind == .word || p.item.kind == .note {
                            Text(p.item.text ?? "")
                                .font(.display(11))
                                .foregroundStyle(Color(hex: 0x0B1316))
                                .multilineTextAlignment(.center)
                                .lineLimit(4)
                                .minimumScaleFactor(0.7)
                                .padding(5)
                                .frame(width: 74, height: 56)
                                .background(
                                    // Grain sits in the card, behind the text.
                                    ZStack { p.item.kind.orbColor; GrainOverlay().opacity(0.9) }
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                )
                                .blur(radius: hidden.contains(p.item.id) ? 8 : 0)
                        } else {
                            RevealFrame(item: p.item, sharp: settled, hidden: hidden.contains(p.item.id), sound: nil)
                                .frame(width: 74, height: 56)
                        }
                    }
                    // Stack up from the line; wrap into a new column when a stack runs out of room.
                    .position(x: settled ? x + CGFloat(p.stack / rows) * 10 : geo.size.width / 2,
                              y: settled ? lineY - 36 - CGFloat(p.stack % rows) * 62 : geo.size.height / 2)
                }
                HStack {
                    Text(RevealCompiler.edge(opensAt, spanning: sealAt)).font(.copy(11)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Text(RevealCompiler.edge(sealAt, spanning: opensAt)).font(.copy(11)).foregroundStyle(Palette.secondary)
                }
                .frame(width: w)
                .position(x: geo.size.width / 2, y: lineY + 16)

                if showsEnd {
                    HStack(spacing: 14) {
                        Text("That's the chapter.").font(.display(26)).foregroundStyle(Palette.ink)
                        Button("Done") { onDone() }.buttonStyle(.pill)
                    }
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.88)
                    .transition(.opacity)
                }
            }
        }
        .onAppear { withAnimation(.spring(duration: 1.4)) { settled = true } }
    }

    /// Stack frames that would overlap on the timeline.
    private func layout(width: CGFloat) -> [(item: RevealItem, stack: Int)] {
        let span = max(sealAt.timeIntervalSince(opensAt), 1)
        var slots: [CGFloat] = []
        var out: [(item: RevealItem, stack: Int)] = []
        for item in items.sorted(by: { $0.at < $1.at }) {
            let x = CGFloat(item.at.timeIntervalSince(opensAt) / span) * width
            out.append((item, slots.filter { abs($0 - x) < 78 }.count))
            slots.append(x)
        }
        return out
    }
}

// MARK: A friend's phone

/// Joined phones follow the host's step. They don't click; they get hide, pause and leave.
struct RevealCompanionView: View {
    @Environment(NightRoom.self) private var room
    @Environment(RollStore.self) private var store
    @State private var confirmHide: RevealItem?

    private var step: RevealStep { room.steps.indices.contains(room.step) ? room.steps[room.step] : .title }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 18) {
                HStack(spacing: 6) {
                    Circle().fill(room.reconnecting ? .orange : .green).frame(width: 6, height: 6)
                    Text(room.reconnecting ? "Finding the TV again…" : "In the room · \(room.setup?.title ?? "")")
                        .font(.tag(12)).foregroundStyle(Palette.secondary)
                }
                .padding(.top, 20)
                Spacer()
                content
                Spacer()
                controls.padding(.bottom, 30)
            }
            .padding(.horizontal, 24)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .title:
            VStack(spacing: 8) {
                Text(room.setup?.title ?? "").font(.display(40)).foregroundStyle(Palette.ink)
                Text("Eyes on the TV.").font(.displayItalic(20)).foregroundStyle(Palette.secondary)
            }
        case .develop:
            Text("What do you think is in there?")
                .font(.display(32)).foregroundStyle(Palette.ink).multilineTextAlignment(.center)
        case .interlude(let from, let to):
            Text("\(RevealCompiler.time(from)) → \(RevealCompiler.time(to))")
                .font(.displayItalic(28)).foregroundStyle(Palette.secondary)
        case .moment(let c, let part, let i):
            framesToHide(room.clusters.indices.contains(c) ? [room.clusters[c].parts[part].flatMap { $0 }[i]] : [])
        case .open(let c, let part, _), .together(let c, let part):
            framesToHide(room.clusters.indices.contains(c) ? room.clusters[c].parts[part].flatMap { $0 } : [])
        case .finale, .end:
            ScrollView { framesToHide(room.setup?.items.sorted { $0.at < $1.at } ?? []) }
                .frame(maxHeight: 460)
        }
    }

    private func framesToHide(_ items: [RevealItem]) -> some View {
        VStack(spacing: 12) {
            Text("Tap one to hide it").font(.copy(13)).foregroundStyle(Palette.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                ForEach(items) { item in
                    let isHidden = room.hidden.contains(item.id)
                    Button { if !isHidden { withAnimation { confirmHide = item } } } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(item.kind.orbColor.opacity(0.55))
                                    .overlay(GrainOverlay().opacity(0.9).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
                                Image(systemName: isHidden ? "eye.slash" : item.kind.symbol)
                                    .foregroundStyle(Palette.ink.opacity(0.85))
                            }
                            .frame(height: 80)
                            .opacity(isHidden ? 0.5 : 1)
                            Text(RevealCompiler.time(item.at)).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if let item = confirmHide {
            VStack(spacing: 12) {
                Text("Hide this \(item.kind.title.lowercased()) from the room?")
                    .font(.display(24)).foregroundStyle(Palette.ink)
                Text("It blurs back on the TV. Nobody sees who hid it.")
                    .font(.copy(13)).foregroundStyle(Palette.secondary)
                HStack(spacing: 12) {
                    Button("Hide it") {
                        room.hide(item.id)
                        store.hideMoment(item.id, in: room.setup?.rollID)
                        withAnimation { confirmHide = nil }
                    }
                    .buttonStyle(.pill)
                    Button("Keep it") { withAnimation { confirmHide = nil } }
                        .buttonStyle(.frostedPill)
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            playbackControls
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            if room.paused {
                if room.iPaused {
                    Button("Resume") { room.setPaused(false) }.buttonStyle(.pill)
                } else {
                    Text("Paused").font(.copy(14)).foregroundStyle(Palette.secondary)
                }
            } else {
                Button("Pause") { room.setPaused(true) }.buttonStyle(.frostedPill)
            }
            Button("Leave") { room.leave() }.buttonStyle(.frostedPill)
        }
    }
}

// MARK: Section by section

/// A section's title and faces, with its moments scattered around it, blurred: you can see something's there.
private struct SectionScene: View {
    var items: [RevealItem]
    var hidden: Set<UUID>
    @State private var shown = false

    private let spots: [CGRect] = [
        CGRect(x: 0.08, y: 0.10, width: 0.30, height: 0.32), CGRect(x: 0.56, y: 0.06, width: 0.22, height: 0.36),
        CGRect(x: 0.53, y: 0.46, width: 0.38, height: 0.42), CGRect(x: 0.18, y: 0.56, width: 0.22, height: 0.30),
        CGRect(x: 0.80, y: 0.14, width: 0.16, height: 0.24), CGRect(x: 0.02, y: 0.48, width: 0.14, height: 0.22),
        CGRect(x: 0.38, y: 0.74, width: 0.16, height: 0.22), CGRect(x: 0.40, y: 0.04, width: 0.14, height: 0.20),
        CGRect(x: 0.84, y: 0.62, width: 0.14, height: 0.24),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(items.prefix(spots.count).enumerated()), id: \.element.id) { i, item in
                    let r = spots[i]
                    RevealFrame(item: item, sharp: false, hidden: hidden.contains(item.id), sound: nil)
                        .frame(width: r.width * geo.size.width, height: r.height * geo.size.height)
                        .position(x: r.midX * geo.size.width, y: r.midY * geo.size.height)
                        .opacity(shown ? 1 : 0)
                        .animation(.easeOut(duration: 0.8).delay(Double(i) * 0.08), value: shown)
                }
                VStack(spacing: 12) {
                    Text(RevealCompiler.section(items.first?.at ?? .now))
                        .font(.display(44)).foregroundStyle(Palette.ink)
                    HStack(spacing: 8) {
                        ForEach(Array(Set(items.map(\.by))).sorted(), id: \.self) { Avatar(name: $0, size: 30) }
                    }
                }
                .shadow(color: .black.opacity(0.7), radius: 18)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .onAppear { shown = true }
    }
}

/// One moment, full screen: blur to sharp, edges feathered into the dark, time and name bottom left.
private struct MomentReveal: View {
    var item: RevealItem
    var hidden: Set<UUID>
    var paused: Bool
    var sound: RevealSound
    @State private var sharp = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                content
                    .frame(width: geo.size.width * 0.8, height: geo.size.height * 0.84)
                    .clipped()
                    .blur(radius: hidden.contains(item.id) ? 40 : (sharp && !paused ? 0 : 30))
                    .mask(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .padding(18)
                            .blur(radius: 22)
                    )
                    .overlay(
                        LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                            .mask(RoundedRectangle(cornerRadius: 30).padding(18).blur(radius: 22))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    Text(RevealCompiler.stamp(item.at)).font(.display(20)).foregroundStyle(Palette.ink)
                    HStack(spacing: 8) {
                        Image(systemName: "eye").font(.system(size: 13))
                        Text(item.by).font(.display(20))
                    }
                    .foregroundStyle(Palette.ink)
                }
                .opacity(sharp ? 1 : 0)
                .padding(.leading, geo.size.width * 0.1 + 24)
                .padding(.bottom, geo.size.height * 0.08 + 30)
            }
        }
        .onAppear {
            Task {
                try? await Task.sleep(for: .seconds(0.3))
                withAnimation(.easeOut(duration: 1.4)) { sharp = true }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .word, .note:
            ZStack {
                item.kind.orbColor.opacity(0.35)
                GrainOverlay().opacity(0.9)
                Text(item.text ?? "")
                    .font(.display(48))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                    .padding(60)
            }
        default:
            RevealFrame(item: item, sharp: true, hidden: false, sound: sound)
        }
    }
}
