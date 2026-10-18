import SwiftUI

/// Home: just the roll you're all adding to. The capture button floats beside it (see RootView).
struct OurRollView: View {
    @Environment(RollStore.self) private var store
    @State private var showSettings = false
    @State private var showRevealNight = false
    @State private var showNewRoll = false
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
                    .accessibilityLabel("Settings")
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

    // MARK: Sealed roll

    private func sealed(_ roll: Roll) -> some View {
        VStack(spacing: 18) {
            VStack(spacing: 2) {
                Text(roll.name).font(.display(30)).foregroundStyle(Palette.ink)
            }

            Spacer(minLength: 0)

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
    }

    /// The sealed roll: everyone's moments stacked and blurred, with the reveal date on top.
    private func hero(_ roll: Roll) -> some View {
        let newestFirst = roll.moments.sorted { $0.createdAt > $1.createdAt }

        return VStack(spacing: 10) {
            ZStack {
                SealedStack(moments: Array(newestFirst.prefix(5)).filter { $0.id != dropping?.id })
                    .frame(height: 340)
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
                    if roll.isReadyToOpen {
                        Text("Ready to open")
                            .font(.tag(13))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Text(roll.revealDate.stamp)
                        .font(.display(52))
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.45), radius: 14)
            }
        }
    }

    // MARK: No active roll

    private var finished: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("That chapter's kept.")
                .font(.display(40))
                .foregroundStyle(Palette.ink)
            Text("Start the next one when you're together again.")
                .font(.copy(16))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
            Button("Start the next chapter") { showNewRoll = true }
                .buttonStyle(.pill)
                .padding(.top, 6)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
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
