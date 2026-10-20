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
    /// Everyone in the chapter, for the title card and the credits. Never tied to a moment.
    private var members: [String] { roll.members.isEmpty ? Array(Set(items.map(\.by))).sorted() : roll.members }

    var body: some View {
        ZStack {
            Palette.backgroundBottom.ignoresSafeArea()
            GrainOverlay().opacity(0.7).ignoresSafeArea()

            Group {
                switch step {
                case .title:
                    TitleCard(title: roll.name, items: items, members: members, opensAt: opensAt, sealAt: sealAt)
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
                case .finale:
                    RecapScene(clusters: room.clusters, opensAt: opensAt, sealAt: sealAt, hidden: room.hidden)
                case .end:
                    WrapScene(clusters: room.clusters, items: items, members: members, opensAt: opensAt, sealAt: sealAt,
                              hidden: room.hidden, onDone: finish)
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

            ReactionLayer(floating: room.floating)
                .allowsHitTesting(false)

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

/// Title card / lobby: chapter title, how long it ran (start to end), a count of each media type,
/// and the whole group's faces coming together, like when the chapter started. Never who's missing.
private struct TitleCard: View {
    var title: String
    var items: [RevealItem]
    var members: [String]
    var opensAt: Date
    var sealAt: Date
    @State private var shown = false
    @State private var gathered = false

    var body: some View {
        GeometryReader { geo in
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.47)
            let n = members.count
            ZStack {
                // The chapter's sealed shape, soft behind the faces once they meet.
                ZStack {
                    ForEach(Array(items.prefix(5).enumerated()), id: \.offset) { k, item in
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(item.kind.orbColor)
                            .frame(width: 150, height: 120)
                            .offset(x: [-70, 40, 80, -40, 0][k], y: [-30, -50, 30, 50, 0][k])
                    }
                }
                .blur(radius: 30)
                .opacity(gathered ? 0.9 : 0)
                .scaleEffect(gathered ? 1 : 0.6)
                .position(c)

                ForEach(Array(members.enumerated()), id: \.element) { k, name in
                    ZStack {
                        Circle().fill(Palette.ink.opacity(0.10)).frame(width: 96, height: 96).blur(radius: 24)
                        Avatar(name: name, size: 56)
                    }
                    .frame(width: 56, height: 56)
                    .position(gathered ? huddle(k, of: n, around: c) : seat(k, of: n, around: c, in: geo.size))
                    .opacity(shown ? 1 : 0)
                    .animation(.easeOut(duration: 0.6).delay(Double(k) * 0.12), value: shown)
                }

                Text(title).font(.display(46)).foregroundStyle(Palette.ink)
                    .position(x: c.x, y: geo.size.height * 0.14)
                VStack(spacing: 10) {
                    Text(RevealCompiler.span(opensAt, sealAt)).font(.display(30)).foregroundStyle(Palette.ink)
                    Text(RevealCompiler.counts(items)).font(.copy(13)).foregroundStyle(Palette.secondary)
                }
                .opacity(gathered ? 1 : 0)
                .animation(.easeOut(duration: 0.8).delay(0.5), value: gathered)
                .position(x: c.x, y: geo.size.height * 0.8)
            }
        }
        .onAppear {
            shown = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.spring(duration: 0.9, bounce: 0.3)) { gathered = true }
            }
        }
    }

    /// Spread out on a ring first.
    private func seat(_ k: Int, of n: Int, around c: CGPoint, in size: CGSize) -> CGPoint {
        let a = -Double.pi / 2 + Double(k) * 2 * .pi / Double(max(n, 1))
        return CGPoint(x: c.x + cos(a) * size.width * 0.3, y: c.y + sin(a) * size.height * 0.3)
    }

    /// Then together: one overlapping row in the middle.
    private func huddle(_ k: Int, of n: Int, around c: CGPoint) -> CGPoint {
        CGPoint(x: c.x + (CGFloat(k) - CGFloat(n - 1) / 2) * 40, y: c.y)
    }
}

/// The sealed chapter develops into soft day shapes on the whole-chapter timeline:
/// each cluster's own frames, blurred together. Bigger shape = more people.
private struct DevelopScene: View {
    var clusters: [RevealCluster]
    var opensAt: Date
    var sealAt: Date
    @State private var shown = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 120
            let y = geo.size.height * 0.6
            ZStack {
                Rectangle().fill(Palette.ink.opacity(0.15)).frame(width: w, height: 1)
                    .position(x: geo.size.width / 2, y: y)
                ForEach(clusters, id: \.index) { c in
                    let size = 44 + CGFloat(c.people) * 22
                    DayShape(items: Array(c.parts.flatMap { $0.flatMap { $0 } }.prefix(5)), size: size)
                        .opacity(shown ? 1 : 0)
                        .scaleEffect(shown ? 1 : 0.4)
                        .position(x: 60 + c.x * w, y: y - size / 2 - 8)
                        .animation(.easeOut(duration: 1.2).delay(Double(c.index) * 0.12), value: shown)
                }
                HStack {
                    Text(RevealCompiler.edge(opensAt, spanning: sealAt)).font(.display(15)).foregroundStyle(Palette.secondary)
                    Spacer()
                    Text(RevealCompiler.edge(sealAt, spanning: opensAt)).font(.display(15)).foregroundStyle(Palette.secondary)
                }
                .frame(width: w)
                .position(x: geo.size.width / 2, y: y + 20)
            }
        }
        .onAppear { shown = true }
    }
}

/// A few of a cluster's frames overlapped and blurred into one soft shape.
private struct DayShape: View {
    var items: [RevealItem]
    var size: CGFloat
    private let spots: [(CGFloat, CGFloat)] = [(-0.2, -0.1), (0.2, -0.16), (0.18, 0.16), (-0.16, 0.2), (0, 0)]

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { k, item in
                RevealFrame(item: item, sharp: false, hidden: false, sound: nil)
                    .frame(width: size * 0.6, height: size * 0.5)
                    .offset(x: spots[k].0 * size, y: spots[k].1 * size)
            }
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .blur(radius: 8)
    }
}

/// One cluster (or half of a big one), everything revealed at once, loosely laid out.
/// Every frame keeps its real shape and fits on screen. Typed words get their own card.
/// Time labels only, no names.
private struct CollageScene: View {
    var groups: [[RevealItem]]
    var peak: Bool
    var hidden: Set<UUID>
    var paused: Bool
    var sound: RevealSound
    @Environment(RollStore.self) private var store
    @State private var sharp = false

    private struct Cell {
        var item: RevealItem
        var size: CGSize
    }

    private let gap: CGFloat = 24
    private let label: CGFloat = 24

    private var flat: [RevealItem] { groups.flatMap { $0 } }

    var body: some View {
        GeometryReader { geo in
            let scale: CGFloat = peak ? 1 : 0.9
            let area = CGSize(width: geo.size.width * 0.86 * scale, height: (geo.size.height - 80) * scale)
            VStack(spacing: 12) {
                Text(timeLabel).font(.display(20)).foregroundStyle(Palette.ink.opacity(0.85))
                    .padding(.top, 16)
                collage(in: area)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            Task {
                try? await Task.sleep(for: .seconds(peak ? 1.2 : 0.2))
                sharp = true
            }
        }
    }

    private var timeLabel: String {
        guard let first = flat.first?.at, let last = flat.last?.at else { return "" }
        let a = RevealCompiler.time(first), b = RevealCompiler.time(last)
        return a == b ? a : "\(a) – \(b)"
    }

    private func collage(in area: CGSize) -> some View {
        VStack(spacing: gap) {
            ForEach(Array(rows(in: area).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: gap) {
                    ForEach(row, id: \.item.id) { cell in
                        VStack(spacing: 6) {
                            tile(cell)
                                .rotationEffect(.degrees(tilt(cell.item)))
                            Text(RevealCompiler.time(cell.item.at))
                                .font(.display(14))
                                .foregroundStyle(Palette.secondary)
                                .frame(height: label - 6)
                            // What they wrote under it, if anything.
                            if let caption = cell.item.caption, !hidden.contains(cell.item.id) {
                                Text(caption)
                                    .font(.displayItalic(16))
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(1)
                                    .opacity(sharp && !paused ? 1 : 0)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: area.width, height: area.height)
    }

    @ViewBuilder private func tile(_ cell: Cell) -> some View {
        let item = cell.item
        let isHidden = hidden.contains(item.id)
        let on = sharp && !paused
        switch item.kind {
        case .word, .note:
            WordsCard(text: item.text ?? "", kind: item.kind, sharp: on, hidden: isHidden)
                .frame(width: cell.size.width, height: cell.size.height)
        case .voice:
            RevealFrame(item: item, sharp: on, hidden: isHidden, sound: sound)
                .frame(width: cell.size.width, height: cell.size.height)
                .clipShape(Circle())
                .shadow(color: item.kind.orbColor.opacity(0.35), radius: 22)
        default:
            RevealFrame(item: item, sharp: on, hidden: isHidden, sound: sound)
                .frame(width: cell.size.width, height: cell.size.height)
                .overlay(alignment: .bottomLeading) {
                    if let caption = item.caption, !isHidden {
                        Text(caption)
                            .font(.displayItalic(18))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.7), radius: 8)
                            .opacity(on ? 1 : 0)
                            .padding(10)
                    }
                }
        }
    }

    /// A slight tilt per frame, the same every time it opens.
    private func tilt(_ item: RevealItem) -> Double {
        Double(Int(item.id.uuid.0) % 5 - 2)
    }

    private func aspect(_ item: RevealItem) -> CGFloat { RevealShape.aspect(item, store: store) }

    /// Rows in time order. Tries every row count and keeps the one where the frames come out biggest
    /// while all of them, with their time labels, fit the screen.
    private func rows(in area: CGSize) -> [[Cell]] {
        let items = flat
        guard !items.isEmpty else { return [] }
        let ratios = items.map(aspect)
        var best: [[Cell]] = []
        var bestArea: CGFloat = 0
        for count in 1...items.count {
            let target = ratios.reduce(0, +) / CGFloat(count)
            var split: [[Int]] = [[]]
            var sum: CGFloat = 0
            for i in items.indices {
                if sum >= target * 0.9, split.count < count, !split[split.count - 1].isEmpty {
                    split.append([])
                    sum = 0
                }
                split[split.count - 1].append(i)
                sum += ratios[i]
            }
            // Each row fills the width; then everything shrinks together until it fits the height.
            let heights = split.map { row in
                (area.width - gap * CGFloat(row.count - 1)) / row.map { ratios[$0] }.reduce(0, +)
            }
            let room = area.height - CGFloat(split.count) * label - gap * CGFloat(split.count - 1)
            guard room > 0 else { continue }
            let fit = min(1, room / heights.reduce(0, +))
            let cells = split.enumerated().map { r, row in
                row.map { i in Cell(item: items[i], size: CGSize(width: ratios[i] * heights[r] * fit, height: heights[r] * fit)) }
            }
            let covered = cells.joined().reduce(CGFloat(0)) { $0 + $1.size.width * $1.size.height }
            if covered > bestArea {
                bestArea = covered
                best = cells
            }
        }
        return best
    }
}

/// Typed words, on a card of their own in the collage.
private struct WordsCard: View {
    var text: String
    var kind: MomentKind
    var sharp: Bool
    var hidden: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                kind.orbColor
                GrainOverlay().opacity(0.9)
                Text(text)
                    .font(.display(min(40, geo.size.height * 0.2)))
                    .foregroundStyle(Color(hex: 0x0B1316))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.4)
                    .padding(geo.size.height * 0.12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .blur(radius: hidden ? 28 : (sharp ? 0 : 24))
        .scaleEffect(hidden ? 0.85 : 1)
        .opacity(hidden ? 0.45 : 1)
        .animation(.easeOut(duration: 1.4), value: sharp)
        .animation(.easeInOut(duration: 0.6), value: hidden)
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

/// Width over height for a frame at its real shape. Photos and doodles use their own image.
private enum RevealShape {
    static func aspect(_ item: RevealItem, store: RollStore) -> CGFloat {
        switch item.kind {
        case .voice: return 1
        case .word, .note: return 1.35
        default:
            if let moment = store.state.rolls.lazy.flatMap(\.moments).first(where: { $0.id == item.id }),
               let image = store.image(for: moment), image.size.height > 0 {
                return min(max(image.size.width / image.size.height, 0.5), 2)
            }
            return item.kind == .video ? 9.0 / 16 : 3.0 / 4
        }
    }
}

/// A frame at a small size, for the recap, the wrap and the credits.
private struct MiniTile: View {
    var item: RevealItem
    var sharp: Bool
    var hidden: Bool
    var height: CGFloat
    @Environment(RollStore.self) private var store

    var body: some View {
        let width = height * RevealShape.aspect(item, store: store)
        switch item.kind {
        case .word, .note:
            WordsCard(text: item.text ?? "", kind: item.kind, sharp: sharp, hidden: hidden)
                .frame(width: width, height: height)
        case .voice:
            RevealFrame(item: item, sharp: sharp, hidden: hidden, sound: nil)
                .frame(width: height, height: height)
                .clipShape(Circle())
                .shadow(color: item.kind.orbColor.opacity(0.35), radius: 16)
        default:
            RevealFrame(item: item, sharp: sharp, hidden: hidden, sound: nil)
                .frame(width: width, height: height)
        }
    }
}

/// A cluster's frames as a small fanned pile.
private struct Pile: View {
    var items: [RevealItem]
    var size: CGFloat
    var hidden: Set<UUID>
    var sharp: Bool

    static let spots: [(CGFloat, CGFloat)] = [(-0.2, -0.1), (0.2, -0.16), (0.18, 0.16), (-0.16, 0.2), (0, 0)]
    static func tilt(_ k: Int) -> Double { (k % 2 == 0 ? -4 : 4) + Double(k) * 0.5 }
    static func size(_ c: RevealCluster) -> CGFloat { 50 + CGFloat(c.people) * 24 }
    static func items(_ c: RevealCluster) -> [RevealItem] { Array(c.parts.flatMap { $0.flatMap { $0 } }.prefix(5)) }

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { k, item in
                MiniTile(item: item, sharp: sharp, hidden: hidden.contains(item.id), height: size * 0.5)
                    .rotationEffect(.degrees(Pile.tilt(k)))
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 8)
                    .offset(x: Pile.spots[k].0 * size * (sharp ? 1.3 : 1), y: Pile.spots[k].1 * size * (sharp ? 1.3 : 1))
            }
        }
        .frame(width: size, height: size)
    }
}

/// The recap: the develop scene's day shapes come back, now sharp, each a little pile of its frames
/// at its spot on the whole-chapter timeline. The chorus plays over it.
private struct RecapScene: View {
    var clusters: [RevealCluster]
    var opensAt: Date
    var sealAt: Date
    var hidden: Set<UUID>
    @State private var sharp = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 120
            let y = geo.size.height * 0.68
            ZStack {
                Text(RevealCompiler.span(opensAt, sealAt)).font(.display(28)).foregroundStyle(Palette.ink)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.1)
                Rectangle().fill(Palette.ink.opacity(0.15)).frame(width: w, height: 1)
                    .position(x: geo.size.width / 2, y: y)
                ForEach(clusters, id: \.index) { c in
                    let size = Pile.size(c)
                    Pile(items: Pile.items(c), size: size, hidden: hidden, sharp: sharp)
                        .position(x: 60 + CGFloat(c.x) * w, y: y - size / 2 - 12)
                    Text(RevealCompiler.time(c.start)).font(.display(13)).foregroundStyle(Palette.secondary)
                        .position(x: 60 + CGFloat(c.x) * w, y: y + 16)
                }
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 1.4).delay(0.3)) { sharp = true } }
    }
}

/// The wrap, after one more tap: every pile flies into one clump, then credits roll like a movie
/// (faces and names in the middle, the day's pictures rising up both sides, never next to a name),
/// then the faces and the last line. No clip plays here; it ends quiet.
private struct WrapScene: View {
    var clusters: [RevealCluster]
    var items: [RevealItem]
    var members: [String]
    var opensAt: Date
    var sealAt: Date
    var hidden: Set<UUID>
    var onDone: () -> Void
    /// 0 piles on the timeline, 1 one clump, 2 credits, 3 end card.
    @State private var phase = 0
    @State private var rolling = false

    private struct Tile {
        var item: RevealItem
        var x: CGFloat
        var size: CGFloat
        var spot: (CGFloat, CGFloat)
        var tilt: Double
    }

    private var tiles: [Tile] {
        clusters.flatMap { c in
            Pile.items(c).enumerated().map { k, item in
                Tile(item: item, x: CGFloat(c.x), size: Pile.size(c), spot: Pile.spots[k], tilt: Pile.tilt(k))
            }
        }
    }

    private var pictures: [RevealItem] {
        Array(items.filter { ([.photo, .video, .doodle] as [MomentKind]).contains($0.kind) && !hidden.contains($0.id) }
            .sorted { $0.at < $1.at }.prefix(12))
    }

    private struct CreditLine: Hashable {
        var role: String
        var value: String
    }

    private var creditLines: [CreditLine] {
        let n: (MomentKind) -> Int = { k in items.filter { $0.kind == k || (k == .word && $0.kind == .note) }.count }
        let plural: (Int, String, String) -> String = { c, one, many in "\(c) \(c == 1 ? one : many)" }
        let shot = [n(.photo) > 0 ? plural(n(.photo), "photo", "photos") : nil,
                    n(.video) > 0 ? plural(n(.video), "video", "videos") : nil].compactMap { $0 }
        return [
            CreditLine(role: "shot on", value: shot.joined(separator: ", ")),
            CreditLine(role: "sound", value: n(.voice) > 0 ? plural(n(.voice), "voice note", "voice notes") : ""),
            CreditLine(role: "art", value: n(.doodle) > 0 ? plural(n(.doodle), "doodle", "doodles") : ""),
            CreditLine(role: "written in", value: n(.word) > 0 ? "\(n(.word)) words" : ""),
        ].filter { !$0.value.isEmpty }
    }

    private var creditsHeight: CGFloat { 80 + CGFloat(members.count) * 80 + CGFloat(creditLines.count) * 36 + 40 }
    private var creditsDuration: Double { max(10, Double(members.count) * 2.2 + 7) }

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                clump(in: geo.size, center: center)
                    .opacity(phase >= 2 ? 0 : 1)
                    .scaleEffect(phase >= 2 ? 0.6 : 1)
                    .offset(y: phase >= 2 ? -geo.size.height * 0.3 : 0)
                credits(in: geo.size)
                    .opacity(phase == 2 ? 1 : 0)
                endCard
                    .opacity(phase == 3 ? 1 : 0)
                    .allowsHitTesting(phase == 3)
                    .position(center)
            }
        }
        .task { await play() }
    }

    private func play() async {
        try? await Task.sleep(for: .seconds(0.4))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 1.6)) { phase = 1 }
        try? await Task.sleep(for: .seconds(3.4))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 1.0)) { phase = 2 }
        withAnimation(.linear(duration: creditsDuration)) { rolling = true }
        try? await Task.sleep(for: .seconds(creditsDuration))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 1.2)) { phase = 3 }
    }

    private func clump(in size: CGSize, center: CGPoint) -> some View {
        let w = size.width - 120
        let lineY = size.height * 0.68
        return ZStack {
            Rectangle().fill(Palette.ink.opacity(0.15)).frame(width: phase == 0 ? w : 0, height: 1)
                .position(x: center.x, y: lineY)
            Text(RevealCompiler.span(opensAt, sealAt)).font(.display(28)).foregroundStyle(Palette.ink)
                .position(x: center.x, y: size.height * 0.1)
                .opacity(phase == 0 ? 1 : 0)
            ForEach(Array(tiles.enumerated()), id: \.element.item.id) { i, t in
                // Where it sat in the recap, and where it lands in the clump (a tight spiral).
                let spot = CGPoint(x: 60 + t.x * w + t.spot.0 * t.size * 1.3,
                                   y: lineY - t.size / 2 - 12 + t.spot.1 * t.size * 1.3)
                let a = CGFloat(i) * 2.4
                let r = 16 * CGFloat(i).squareRoot()
                let home = CGPoint(x: center.x + cos(a) * r * 1.6, y: center.y + sin(a) * r)
                MiniTile(item: t.item, sharp: true, hidden: hidden.contains(t.item.id), height: t.size * 0.5)
                    .rotationEffect(.degrees(t.tilt))
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 8)
                    .position(phase == 0 ? spot : home)
            }
        }
        .scaleEffect(phase == 1 ? 1.25 : 1)
    }

    private func credits(in size: CGSize) -> some View {
        let travel = size.height + creditsHeight
        return ZStack {
            // The day's pictures rise up both sides, a little faster than the names.
            ForEach(Array(pictures.enumerated()), id: \.element.id) { k, item in
                MiniTile(item: item, sharp: true, hidden: false, height: 120)
                    .rotationEffect(.degrees(k % 2 == 0 ? -3 : 3))
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 10)
                    .position(x: k % 2 == 0 ? size.width * 0.14 : size.width * 0.86,
                              y: size.height + 100 + CGFloat(k / 2) * 190 - (rolling ? travel * 1.3 : 0))
            }
            VStack(spacing: 22) {
                Text("starring").font(.displayItalic(22)).foregroundStyle(Palette.secondary)
                ForEach(members, id: \.self) { name in
                    HStack(spacing: 18) {
                        Avatar(name: name, size: 58)
                        Text(name).font(.display(32)).foregroundStyle(Palette.ink)
                        Spacer(minLength: 0)
                    }
                    .frame(width: 300)
                }
                VStack(spacing: 10) {
                    ForEach(creditLines, id: \.role) { line in
                        HStack(spacing: 24) {
                            Text(line.role).font(.displayItalic(20)).foregroundStyle(Palette.secondary)
                                .frame(width: 170, alignment: .trailing)
                            Text(line.value).font(.display(20)).foregroundStyle(Palette.ink)
                                .frame(width: 170, alignment: .leading)
                        }
                    }
                }
                .padding(.top, 30)
            }
            .position(x: size.width / 2, y: size.height + creditsHeight / 2 - (rolling ? travel : 0))
        }
    }

    private var endCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: -14) {
                ForEach(members, id: \.self) { Avatar(name: $0, size: 64) }
            }
            Text("Ready for the next chapter.")
                .font(.display(52)).foregroundStyle(Palette.ink)
                .padding(.top, 40)
            Text("\(items.count) \(items.count == 1 ? "moment" : "moments") · \(RevealCompiler.span(opensAt, sealAt))")
                .font(.displayItalic(22)).foregroundStyle(Palette.secondary)
                .padding(.top, 16)
            Button("Done") { onDone() }
                .buttonStyle(.pill)
                .padding(.top, 44)
        }
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
                Text("It blurs back on the TV. Nobody sees who.")
                    .font(.copy(13)).foregroundStyle(Palette.secondary)
                HStack(spacing: 12) {
                    Button("Hide it") {
                        room.hide(item.id)
                        store.hideMoment(item.id, in: room.setup?.rollID)
                        withAnimation { confirmHide = nil }
                    }
                    .buttonStyle(.pill)
                    Button("Leave it") { withAnimation { confirmHide = nil } }
                        .buttonStyle(.frostedPill)
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            playbackControls
        }
    }

    private var playbackControls: some View {
        VStack(spacing: 22) {
            HStack(spacing: 14) {
                ForEach(NightRoom.Reaction.allCases, id: \.self) { r in
                    Button { room.react(r) } label: {
                        ReactionGlyph(reaction: r)
                            .stroke(Palette.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .frame(width: 30, height: 30)
                            .frame(width: 58, height: 58)
                            .overlay(Circle().stroke(Color(hex: 0x3A4456), lineWidth: 1.5))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(r.label)
                }
            }
            transport
        }
    }

    private var transport: some View {
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

// MARK: Reactions

/// Reactions floating up over the TV: a soft disc in a type colour with a hand-drawn face, rising and fading.
private struct ReactionLayer: View {
    var floating: [NightRoom.Floating]

    var body: some View {
        GeometryReader { geo in
            ForEach(floating) { f in
                ReactionFloat(reaction: f.reaction, x: f.x * geo.size.width, height: geo.size.height)
            }
        }
        .ignoresSafeArea()
    }
}

private struct ReactionFloat: View {
    var reaction: NightRoom.Reaction
    var x: CGFloat
    var height: CGFloat
    @State private var up = false
    @State private var gone = false
    @State private var drift = CGFloat.random(in: -24...24)

    private var color: Color {
        switch reaction {
        case .laugh: Color(hex: 0x7F7E44)
        case .cry: Color(hex: 0x5C757D)
        case .heart: Color(hex: 0x70456F)
        case .gasp: Color(hex: 0x1C4E5E)
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(color)
            ReactionGlyph(reaction: reaction)
                .stroke(Palette.ink, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .padding(13)
        }
        .frame(width: 64, height: 64)
        .shadow(color: color.opacity(0.35), radius: 26)
        .scaleEffect(up ? 1 : 0.5)
        .opacity(gone ? 0 : 1)
        .position(x: x + (up ? drift : 0), y: up ? height * 0.3 : height + 40)
        .onAppear {
            withAnimation(.easeOut(duration: 3)) { up = true }
            withAnimation(.easeIn(duration: 1).delay(2.2)) { gone = true }
        }
    }
}

/// Hand-drawn reaction faces, drawn as strokes in a square box. The face loop is left a little open on purpose.
struct ReactionGlyph: Shape {
    var reaction: NightRoom.Reaction

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let p: (CGFloat, CGFloat) -> CGPoint = { CGPoint(x: rect.minX + $0 * w, y: rect.minY + $1 * h) }
        var path = Path()
        if reaction == .heart {
            path.move(to: p(0.5, 0.86))
            path.addCurve(to: p(0.1, 0.38), control1: p(0.3, 0.7), control2: p(0.08, 0.54))
            path.addCurve(to: p(0.5, 0.28), control1: p(0.12, 0.12), control2: p(0.42, 0.1))
            path.addCurve(to: p(0.9, 0.38), control1: p(0.58, 0.1), control2: p(0.88, 0.12))
            path.addCurve(to: p(0.5, 0.86), control1: p(0.92, 0.54), control2: p(0.7, 0.7))
            return path
        }
        path.addArc(center: p(0.5, 0.5), radius: w * 0.44, startAngle: .degrees(-70), endAngle: .degrees(265), clockwise: false)
        switch reaction {
        case .laugh:
            path.move(to: p(0.3, 0.42)); path.addQuadCurve(to: p(0.42, 0.42), control: p(0.36, 0.3))
            path.move(to: p(0.58, 0.42)); path.addQuadCurve(to: p(0.7, 0.42), control: p(0.64, 0.3))
            path.move(to: p(0.28, 0.58)); path.addQuadCurve(to: p(0.72, 0.58), control: p(0.5, 0.9))
            path.addLine(to: p(0.28, 0.58))
        case .cry:
            path.move(to: p(0.3, 0.4)); path.addQuadCurve(to: p(0.42, 0.4), control: p(0.36, 0.47))
            path.move(to: p(0.58, 0.4)); path.addQuadCurve(to: p(0.7, 0.4), control: p(0.64, 0.47))
            path.addEllipse(in: CGRect(origin: p(0.31, 0.5), size: CGSize(width: w * 0.07, height: h * 0.1)))
            path.move(to: p(0.36, 0.74)); path.addQuadCurve(to: p(0.64, 0.74), control: p(0.5, 0.6))
        case .gasp:
            path.addEllipse(in: CGRect(origin: p(0.34, 0.37), size: CGSize(width: w * 0.06, height: h * 0.06)))
            path.addEllipse(in: CGRect(origin: p(0.6, 0.37), size: CGSize(width: w * 0.06, height: h * 0.06)))
            path.addEllipse(in: CGRect(origin: p(0.42, 0.56), size: CGSize(width: w * 0.16, height: h * 0.2)))
        case .heart:
            break
        }
        return path
    }
}

// MARK: Section by section

/// A section's title, with its moments scattered around it, blurred: you can see something's there.
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
                Text(RevealCompiler.section(items.first?.at ?? .now))
                    .font(.display(44)).foregroundStyle(Palette.ink)
                .shadow(color: .black.opacity(0.7), radius: 18)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .onAppear { shown = true }
    }
}

/// One moment, full screen: blur to sharp, edges feathered into the dark, time bottom left.
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

                Text(RevealCompiler.stamp(item.at)).font(.display(20)).foregroundStyle(Palette.ink)
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
