import SwiftUI
import MultipeerConnectivity

/// Reveal-night sync (reveal-logic.md §5). The host (the phone on the TV) owns the step; joined phones
/// compile the same steps from the same frozen metadata and follow. Joined phones can hide, pause and leave.
/// Peer-to-peer, so it works with no server, as long as phones are in the same room.
@Observable
final class NightRoom: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    static let serviceType = "presents-night"

    nonisolated struct Setup: Codable, Sendable {
        var rollID: UUID
        var title: String
        var opensAt: Date
        var sealAt: Date
        var items: [RevealItem]
        var hidden: [UUID]
    }

    nonisolated enum Message: Codable, Sendable {
        case setup(Setup, step: Int, paused: Bool)
        case step(Int)
        case hide(UUID)          // no sender, ever
        case pause(Bool)
        case whereAreWe
        /// Host heartbeat every 2 s: keeps late or flaky phones on the right step.
        case beat(step: Int, paused: Bool, hidden: [UUID])
    }

    enum Role { case idle, host, guest }

    private(set) var role: Role = .idle

    // Shared state (both sides)
    var setup: Setup?
    var steps: [RevealStep] = []
    var clusters: [RevealCluster] = []
    var step = 0
    var paused = false
    var hidden: Set<UUID> = []
    /// True on the phone that pressed pause, so it can resume.
    var iPaused = false

    // Host side
    var inRoom: [String] = []
    @ObservationIgnored var onHide: ((UUID) -> Void)?
    @ObservationIgnored private var pausedBy: MCPeerID?

    @ObservationIgnored private var session: MCSession?
    @ObservationIgnored private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored private var browser: MCNearbyServiceBrowser?
    @ObservationIgnored private var listeningFor: Set<String> = []
    @ObservationIgnored private var listenName = ""
    @ObservationIgnored private var hostingRoll: UUID?
    /// A roll this phone chose to leave tonight; don't rejoin it automatically.
    @ObservationIgnored private var leftRoll: UUID?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var lastHeard = Date.distantPast
    /// Hides and pauses made while the link was down; sent once it's back.
    @ObservationIgnored private var outbox: [Message] = []
    /// Guest: true while the TV hasn't been heard from for a few seconds.
    var reconnecting = false

    private func makeSession(_ name: String) -> MCSession {
        let peer = MCPeerID(displayName: String((name.isEmpty ? "Friend" : name).prefix(40)))
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session
        return session
    }

    // MARK: Host

    /// Compile once, at open, from metadata only.
    func host(_ setup: Setup, me: String) {
        if role == .host, hostingRoll == setup.rollID { return }
        stop()
        role = .host
        hostingRoll = setup.rollID
        apply(setup)
        let session = makeSession(me)
        let advertiser = MCNearbyServiceAdvertiser(peer: session.myPeerID, discoveryInfo: ["roll": setup.rollID.uuidString], serviceType: Self.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.role == .host else { return }
                self.send(.beat(step: self.step, paused: self.paused, hidden: Array(self.hidden)))
            }
        }
    }

    /// Only the host advances. While paused, it can't.
    func go(to newStep: Int) {
        guard role == .host, !paused, steps.indices.contains(newStep) else { return }
        step = newStep
        send(.step(newStep))
    }

    func hostResume() {
        guard role == .host else { return }
        paused = false
        pausedBy = nil
        send(.pause(false))
    }

    // MARK: Guest

    func listen(rollIDs: [UUID], me: String) {
        let ids = Set(rollIDs.filter { $0 != leftRoll }.map(\.uuidString))
        guard role != .host, role != .guest, ids != listeningFor || browser == nil else { return }
        stop()
        guard !ids.isEmpty else { return }
        listeningFor = ids
        listenName = me
        let session = makeSession(me)
        let browser = MCNearbyServiceBrowser(peer: session.myPeerID, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
        // Watchdog: if the TV goes quiet, drop the dead link and find it again.
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                guard self.role == .guest else { continue }
                let quiet = Date.now.timeIntervalSince(self.lastHeard)
                self.reconnecting = quiet > 5
                if quiet > 7 { self.reconnect() }
            }
        }
    }

    func hide(_ id: UUID) {
        hidden.insert(id)
        sendOrQueue(.hide(id))
    }

    func setPaused(_ on: Bool) {
        if on { iPaused = true } else { guard iPaused else { return }; iPaused = false }
        sendOrQueue(.pause(on))
    }

    private func sendOrQueue(_ message: Message) {
        if let session, !session.connectedPeers.isEmpty, !reconnecting {
            send(message)
        } else {
            outbox.append(message)
        }
    }

    /// Keep what's on screen, replace the connection underneath.
    private func reconnect() {
        let ids = listeningFor
        let me = listenName
        session?.disconnect()
        browser?.stopBrowsingForPeers()
        lastHeard = .now
        role = .idle
        let session = makeSession(me)
        listeningFor = ids
        let browser = MCNearbyServiceBrowser(peer: session.myPeerID, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    /// Step out; the room carries on.
    func leave() {
        leftRoll = setup?.rollID
        stop()
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        outbox = []
        reconnecting = false
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        listeningFor = []
        hostingRoll = nil
        role = .idle
        setup = nil
        steps = []
        clusters = []
        step = 0
        paused = false
        iPaused = false
        hidden = []
        inRoom = []
    }

    // MARK: Internals

    private func apply(_ setup: Setup) {
        self.setup = setup
        let compiled = RevealCompiler.compile(setup.items, opensAt: setup.opensAt, sealAt: setup.sealAt)
        clusters = compiled.clusters
        steps = compiled.steps
        hidden = Set(setup.hidden)
    }

    private func send(_ message: Message, to peers: [MCPeerID]? = nil) {
        guard let session, !session.connectedPeers.isEmpty, let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: peers ?? session.connectedPeers, with: .reliable)
    }

    // MARK: Delegates (called off the main thread)

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in invitationHandler(true, self.session) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard let roll = info?["roll"] else { return }
        Task { @MainActor in
            guard self.role == .idle, self.listeningFor.contains(roll), let session = self.session,
                  session.connectedPeers.isEmpty else { return }
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 20)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let name = peerID.displayName
        Task { @MainActor in
            switch (state, self.role) {
            case (.connected, .host):
                if !self.inRoom.contains(name) { self.inRoom.append(name) }
                if let setup = self.setup {
                    var current = setup
                    current.hidden = Array(self.hidden)
                    self.send(.setup(current, step: self.step, paused: self.paused), to: [peerID])
                }
            case (.connected, .idle):
                self.role = .guest
                self.lastHeard = .now
                self.send(.whereAreWe)
            case (.notConnected, .host):
                self.inRoom.removeAll { $0 == name }
                if self.pausedBy == peerID { self.pausedBy = nil }
            case (.notConnected, .guest):
                // Lost the TV: keep the screen, find it again.
                self.reconnecting = true
                self.reconnect()
            default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
        Task { @MainActor in
            if self.role == .guest {
                self.lastHeard = .now
                self.reconnecting = false
            }
            switch (message, self.role) {
            case (.setup(let setup, let step, let paused), .guest):
                let mine = self.hidden
                self.apply(setup)
                self.hidden.formUnion(mine)
                self.step = step
                self.paused = paused
                // Anything done while the link was down goes out now.
                let pending = self.outbox
                self.outbox = []
                for m in pending { self.send(m) }
            case (.beat(let step, let paused, let hidden), .guest):
                self.step = step
                self.paused = paused
                self.hidden.formUnion(hidden)
            case (.step(let n), .guest):
                self.step = n
            case (.hide(let id), _):
                self.hidden.insert(id)
                if self.role == .host {
                    self.onHide?(id)
                    self.send(.hide(id))     // rebroadcast, no sender
                }
            case (.pause(let on), .host):
                if on {
                    self.paused = true
                    self.pausedBy = peerID
                    self.send(.pause(true))
                } else if self.pausedBy == peerID {
                    self.hostResume()
                }
            case (.pause(let on), .guest):
                self.paused = on
                if !on { self.iPaused = false }
            case (.whereAreWe, .host):
                self.send(.step(self.step), to: [peerID])
            default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
