import SwiftUI

/// Home: just the roll you're all adding to. The capture button floats beside it (see RootView).
struct OurRollView: View {
    @Environment(RollStore.self) private var store
    @State private var showSettings = false
    @State private var showRevealNight = false
    @State private var showNewRoll = false
    /// "Document this?" stays quiet for a while after a yes or a not now.
    @AppStorage("nudgeQuietUntil") private var quietUntil: Double = 0
    /// The moment you just sealed, mid-drop into the stack.
    @State private var dropping: Moment?
    @State private var stackBump = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                if let roll = store.activeRoll {
                    sealed(roll)
                } else {
                    finished
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Avatar(name: store.state.me, size: 34)
                    }
                    .accessibilityLabel("Profile and group settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showNewRoll) {
                StartRollView { showNewRoll = false }
            }
            .fullScreenCover(isPresented: $showRevealNight) { RevealNightView() }
            .onChange(of: store.justSealed) { _, moment in
                guard let moment else { return }
                store.justSealed = nil
                // Wait for the capture screen to slide away, then drop it in.
                Task {
                    try? await Task.sleep(for: .seconds(0.45))
                    dropping = moment
                }
            }
        }
    }

    private var showNudge: Bool {
        store.state.presencePromptsOn && !store.togetherNow.isEmpty && Date.now.timeIntervalSince1970 > quietUntil
    }

    // MARK: Sealed roll

    private func sealed(_ roll: Roll) -> some View {
        VStack(spacing: 18) {
            VStack(spacing: 2) {
                Text(roll.name).font(.display(30)).foregroundStyle(Palette.ink)
                TagLabel("\(roll.members.count) of us")
            }

            Spacer(minLength: 0)

            if showNudge {
                TogetherNudge(people: store.togetherNow) {
                    quietUntil = Date.now.addingTimeInterval(60 * 60).timeIntervalSince1970
                    store.captureRequest = CaptureRequest(with: store.togetherNow)
                } notNow: {
                    withAnimation { quietUntil = Date.now.addingTimeInterval(2 * 60 * 60).timeIntervalSince1970 }
                }
                .padding(.horizontal, 20)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            hero(roll)

            if roll.isReadyToOpen {
                Button("Open it together") { showRevealNight = true }
                    .buttonStyle(.pill)
            }

            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .padding(.bottom, 96)
        .animation(.spring(duration: 0.45), value: showNudge)
    }

    /// The sealed roll: everyone's moments stacked and blurred, with the reveal date on top.
    private func hero(_ roll: Roll) -> some View {
        let newestFirst = roll.moments.sorted { $0.createdAt > $1.createdAt }

        return VStack(spacing: 10) {
            ZStack {
                SealedStack(moments: Array(newestFirst.prefix(5)).filter { $0.id != dropping?.id })
                    .frame(height: showNudge ? 250 : 340)
                    .scaleEffect(stackBump ? 1.05 : 1)
                if let dropping {
                    SealDrop(moment: dropping) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { stackBump = true }
                        Task {
                            try? await Task.sleep(for: .seconds(0.18))
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { stackBump = false }
                            self.dropping = nil
                        }
                    }
                    .offset(x: 5, y: -78)
                }
                VStack(spacing: 4) {
                    Text(roll.isReadyToOpen ? "Ready to open" : "Opens")
                        .font(.tag(13))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(roll.revealDate.stamp)
                        .font(.display(showNudge ? 40 : 52))
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.45), radius: 14)
            }
            Text(newestFirst.count == 1 ? "1 moment sealed" : "\(newestFirst.count) moments sealed")
                .font(.copy(14))
                .foregroundStyle(Palette.secondary)
        }
    }

    // MARK: No active roll

    private var finished: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("That chapter's kept.")
                .font(.display(40))
                .foregroundStyle(Palette.ink)
            Text("Start another when you're all together again.")
                .font(.copy(16))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
            Button("Start a new roll") { showNewRoll = true }
                .buttonStyle(.pill)
                .padding(.top, 6)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}

/// Shown when the app notices other members nearby. One tap and the roll picks the format.
struct TogetherNudge: View {
    var people: [String]
    var yes: () -> Void
    var notNow: () -> Void

    var body: some View {
        GlassCard(padding: 18, radius: 26) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    HStack(spacing: -8) {
                        ForEach(people.prefix(4), id: \.self) { Avatar(name: $0, size: 28) }
                    }
                    Text("Nearby").font(.tag(12)).foregroundStyle(Palette.secondary)
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
                Text("You're with \(Together.names(people)).")
                    .font(.display(28))
                    .foregroundStyle(Palette.ink)
                Text("Want to document this?")
                    .font(.copy(15))
                    .foregroundStyle(Palette.secondary)
                HStack(spacing: 10) {
                    Button("Yes, document this", action: yes).buttonStyle(.pill)
                    Button("Not now", action: notNow).buttonStyle(.frostedPill)
                }
            }
        }
    }
}

/// What you just sealed, dropping into the roll: it rises in already going soft,
/// hangs for a beat, then tips and sinks into the stack. You never get a clear look at it again.
struct SealDrop: View {
    var moment: Moment
    var landed: () -> Void
    @State private var phase = 0   // 0 arriving, 1 held, 2 dropped

    var body: some View {
        MomentThumb(moment: moment)
            .frame(width: 190, height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
            .blur(radius: phase == 0 ? 6 : phase == 1 ? 8 : 14)
            .scaleEffect(phase == 0 ? 1.25 : phase == 1 ? 1 : 0.55)
            .rotationEffect(.degrees(phase == 2 ? -6 : 3))
            .offset(y: phase == 0 ? -260 : phase == 1 ? -40 : 78)
            .opacity(phase == 2 ? 0 : 1)
            .allowsHitTesting(false)
            .task {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.75)) { phase = 1 }
                try? await Task.sleep(for: .seconds(0.75))
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.easeIn(duration: 0.38)) { phase = 2 }
                try? await Task.sleep(for: .seconds(0.36))
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                landed()
            }
    }
}
