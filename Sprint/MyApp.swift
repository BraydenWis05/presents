import SwiftUI

@main struct PresentsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = RollStore()
    @State private var presence = PresenceMonitor()
    @State private var night = NightRoom()

    init() {
        Fonts.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(presence)
                .environment(night)
        }
    }
}

struct RootView: View {
    @Environment(RollStore.self) private var store
    @Environment(PresenceMonitor.self) private var presence
    @Environment(NightRoom.self) private var night
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Tab = .roll
    /// True after the app has been in the background, so coming back opens the picker again.
    @State private var wasAway = true

    enum Tab { case roll, chapters }

    var body: some View {
        @Bindable var store = store

        Group {
            if store.state.rolls.isEmpty {
                StartRollView()
            } else {
                ZStack(alignment: .bottom) {
                    switch tab {
                    case .roll: OurRollView()
                    case .chapters: ChaptersView()
                    }
                    HStack(alignment: .center) {
                        TabPills(tab: $tab)
                        Spacer()
                        CaptureButton(enabled: store.activeRoll != nil) {
                            store.captureRequest = CaptureRequest(with: store.togetherNow)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                }
                .fullScreenCover(item: $store.captureRequest) { request in
                    CaptureView(with: request.with)
                }
            }
        }
        .tint(Palette.ink)
        .preferredColorScheme(.dark)
        // Keep groups in step across phones while the app is open.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await store.syncWithCloud()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        // A friend started presentation night: this phone becomes a controller, over everything.
        .overlay {
            if night.role == .guest, night.setup != nil {
                RevealCompanionView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: night.role == .guest)
        .onChange(of: night.role) { _, role in
            if role == .guest { store.captureRequest = nil }
        }
        .onChange(of: night.setup?.rollID) { _, id in
            if night.role == .guest, let id { store.markRevealed(id) }
        }
        .onAppear { updatePresence(); store.refreshWidget(); openToPicker(); listenForNight() }
        .onChange(of: scenePhase) { _, phase in
            updatePresence()
            listenForNight()
            if phase == .background { wasAway = true }
            if phase == .active { openToPicker() }
        }
        .onChange(of: store.activeRoll?.id) { updatePresence() }
        .onChange(of: store.state.presencePromptsOn) { updatePresence() }
        .onChange(of: presence.together) { _, together in store.togetherNow = together }
        .sheet(isPresented: Binding(get: { store.pendingInvite != nil }, set: { if !$0 { store.pendingInvite = nil } })) {
            if let invite = store.pendingInvite {
                JoinFromLinkView(invite: invite)
            }
        }
        .onOpenURL { url in
            guard url.scheme == "presents" else { return }
            if url.host == "join" {
                if let invite = RollInvite(link: url), store.roll(invite.rollID) == nil {
                    store.captureRequest = nil
                    store.pendingInvite = invite
                }
                return
            }
            tab = .roll
            if url.host == "capture", store.activeRoll != nil {
                store.captureRequest = CaptureRequest(with: store.togetherNow)
            }
        }
    }

    /// The app opens straight into the media picker. Close it to see the roll.
    private func openToPicker() {
        guard wasAway else { return }
        wasAway = false
        guard night.role != .guest, let roll = store.activeRoll, !roll.isReadyToOpen, store.captureRequest == nil else { return }
        tab = .roll
        store.captureRequest = CaptureRequest(with: store.togetherNow)
    }

    /// While the app is open, watch for a friend starting presentation night for one of our rolls.
    private func listenForNight() {
        guard night.role != .host else { return }
        guard scenePhase == .active else { if night.role == .idle { night.stop() }; return }
        let ids = [store.activeRoll?.id, store.chapters.first?.id].compactMap { $0 }
        night.listen(rollIDs: ids, me: store.state.me)
    }

    /// Look for other members only while the app is open and they've opted in.
    private func updatePresence() {
        if scenePhase == .active, store.state.presencePromptsOn, let roll = store.activeRoll {
            presence.start(me: store.state.me, rollID: roll.id, members: roll.members)
        } else if scenePhase != .inactive {
            presence.stop()
        }
    }
}

/// Our Roll / Chapters, as a small floating pill on the left.
struct TabPills: View {
    @Binding var tab: RootView.Tab

    var body: some View {
        HStack(spacing: 2) {
            tabButton("Our Roll", .roll)
            tabButton("Chapters", .chapters)
        }
        .padding(5)
        .background(Capsule().fill(.ultraThinMaterial).overlay(Capsule().fill(Palette.fill)).overlay(Capsule().stroke(Palette.stroke, lineWidth: 0.6)))
    }

    private func tabButton(_ title: String, _ value: RootView.Tab) -> some View {
        Button(title) { tab = value }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tab == value ? Palette.ink : Palette.secondary)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Capsule().fill(tab == value ? Palette.fill : .clear))
    }
}

/// The capture button, floating off to the side.
struct CaptureButton: View {
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            FiveDotMark(dotColor: Color(hex: 0x0B1316))
                .frame(width: 26, height: 26)
                .frame(width: 62, height: 62)
                .background(Circle().fill(Palette.ink))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel("Add to the roll")
    }
}

/// The five moment colors merged into one soft glow behind the white five-dot mark.
struct MomentGlowIcon: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                Circle().fill(Color(hex: 0x0B151A))
                ForEach(Array(MomentKind.capturable.enumerated()), id: \.offset) { i, kind in
                    let a = -Double.pi / 2 + Double(i) * 2 * .pi / 5
                    Circle()
                        .fill(kind.orbColor)
                        .frame(width: s * 0.5, height: s * 0.5)
                        .offset(x: cos(a) * s * 0.17, y: sin(a) * s * 0.17)
                }
                .blur(radius: s * 0.13)
                FiveDotMark(mono: true)
                    .frame(width: s * 0.36, height: s * 0.36)
            }
            .frame(width: s, height: s)
            .clipShape(Circle())
            .overlay(GrainOverlay().opacity(0.6).clipShape(Circle()))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
