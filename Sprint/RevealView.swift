import SwiftUI

enum RevealMode: String, CaseIterable, Identifiable {
    case slideshow = "Slideshow"
    case movie = "Mini-movie"
    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .slideshow: "Tap through together, at your own pace."
        case .movie: "Plays on its own, voices and all. Sit back."
        }
    }
}

/// Reveal night: the pink "tonight it opens" screen, then the reveal itself.
struct RevealNightView: View {
    @Environment(RollStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var mode: RevealMode = .movie
    @State private var openedRollID: UUID?

    var body: some View {
        if let id = openedRollID, let roll = store.roll(id) {
            PresentationNight(roll: roll) { dismiss() }
        } else if let roll = store.activeRoll {
            night(roll)
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }

    private func night(_ roll: Roll) -> some View {
        ZStack {
            AppBackground(intense: true)
            Sparkles(count: 12)
            VStack(spacing: 22) {
                HStack {
                    Button("Not yet") { dismiss() }
                        .buttonStyle(.frostedPill)
                    Spacer()
                    AirPlayButton().frame(width: 44, height: 44)
                }
                Spacer()
                TagLabel("Reveal night · \(roll.name)")
                Text("Tonight,\nthe roll opens.")
                    .font(.display(46))
                    .multilineTextAlignment(.center)
                Text("\(roll.moments.count) moments from \(roll.members.count) of you.\nOpen when we're all together.")
                    .font(.copy(16))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.secondary)

                Text("Turn your phone sideways and put it on the TV.")
                    .font(.copy(13))
                    .foregroundStyle(Palette.secondary)
                Spacer()
                Label("AirPlay or mirror to the TV", systemImage: "tv")
                    .font(.copy(13))
                    .foregroundStyle(Palette.secondary)
                Button("Open it") {
                    openedRollID = roll.id
                    withAnimation(.easeInOut(duration: 0.6)) { store.reveal() }
                }
                .buttonStyle(.pill)
                .disabled(roll.moments.isEmpty)
            }
            .foregroundStyle(Palette.ink)
            .padding(24)
        }
    }
}

/// Plays a revealed roll. Simple ordering and transitions, no AI storytelling.
struct RevealPlayer: View {
    var roll: Roll
    var mode: RevealMode
    var onFinish: () -> Void

    @Environment(RollStore.self) private var store
    @State private var index = -1
    @State private var player = ClipPlayer()
    @State private var autoAdvance: Task<Void, Never>?

    private var moments: [Moment] { roll.revealOrder }

    var body: some View {
        ZStack {
            AppBackground()

            Group {
                if index < 0 {
                    titleCard
                } else if index < moments.count {
                    MomentCard(
                        moment: moments[index],
                        rollID: roll.id,
                        kenBurns: mode == .movie,
                        isPlayingVoice: player.isPlaying,
                        page: (index, moments.count)
                    ) {
                        if mode == .movie { step(1) }
                    }
                    .padding(.top, 70)
                } else {
                    endCard
                }
            }
            .id(index)
            .transition(mode == .movie
                ? .opacity.combined(with: .scale(scale: 0.98))
                : .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))

            VStack {
                HStack(spacing: 4) {
                    ForEach(moments.indices, id: \.self) { i in
                        Capsule()
                            .fill(i <= index ? Palette.accent : Palette.secondary.opacity(0.2))
                            .frame(height: 3)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                HStack {
                    Spacer()
                    AirPlayButton().frame(width: 40, height: 40)
                    Button("Done", systemImage: "xmark") { finish() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.frostedPill)
                }
                .padding(.horizontal, 16)
                Spacer()
                if mode == .slideshow && index < moments.count {
                    TagLabel("Tap to keep going")
                        .padding(.bottom, 20)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .global) { location in
            let goBack = location.x < 90 && index > -1
            step(goBack ? -1 : 1)
        }
        .onChange(of: index) { stage() }
        .onAppear {
            player.onFinish = { [self] in
                if mode == .movie { step(1) }
            }
            stage()
        }
        .onDisappear {
            autoAdvance?.cancel()
            player.stop()
        }
        .statusBarHidden()
    }

    private var titleCard: some View {
        ZStack {
            Sparkles()
            VStack(spacing: 16) {
                TagLabel("\(roll.createdAt.short) – \((roll.revealedAt ?? .now).short)")
                Text(roll.name).font(.display(44)).multilineTextAlignment(.center)
                HStack(spacing: -10) {
                    ForEach(roll.members, id: \.self) { Avatar(name: $0, size: 44) }
                }
                Text(roll.members.joined(separator: " · ")).font(.copy(15)).foregroundStyle(Palette.secondary)
            }
            .foregroundStyle(Palette.ink)
            .padding(28)
        }
    }

    private var endCard: some View {
        ZStack {
        Sparkles()
        VStack(spacing: 18) {
            Text("That's the roll.").font(.display(40))
            Text("It's kept in Chapters. Come back and add what you remember.")
                .font(.copy(16))
                .multilineTextAlignment(.center)
            Button("Keep the chapter") { finish() }
                .buttonStyle(.pill)
        }
        .foregroundStyle(Palette.ink)
        .multilineTextAlignment(.center)
        .padding(28)
        }
    }

    private func step(_ delta: Int) {
        let next = min(max(index + delta, -1), moments.count)
        guard next != index else { return }
        withAnimation(.easeInOut(duration: mode == .movie ? 0.9 : 0.35)) { index = next }
    }

    /// Plays voice memos as they come up; in mini-movie mode, moves on by itself.
    private func stage() {
        autoAdvance?.cancel()
        player.stop()

        let current = (0..<moments.count).contains(index) ? moments[index] : nil
        if let current, current.kind == .voice, let url = store.mediaURL(current) {
            player.play(url)
            return // movie mode advances when the clip ends
        }
        if current?.kind == .video { return } // the clip advances itself when it ends
        guard mode == .movie, index < moments.count else { return }

        let seconds: Double = {
            guard let current else { return 3.5 }
            switch current.kind {
            case .note: return min(4 + Double(current.text.count) / 40, 9)
            default: return 5
            }
        }()
        autoAdvance = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            step(1)
        }
    }

    private func finish() {
        autoAdvance?.cancel()
        player.stop()
        onFinish()
    }
}
