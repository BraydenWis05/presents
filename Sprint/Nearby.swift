import Foundation
import MultipeerConnectivity

/// What the host sends everyone when the group seals the pact.
nonisolated struct RollInvite: Codable, Sendable {
    var rollID: UUID
    var name: String
    var revealDate: Date
    var members: [String]
    /// The group's choice about noticing when they're together.
    var noticeTogether = true
}

/// In-person setup. Every phone advertises and looks at the same time; there's no host.
/// Whoever sorts first by a random key names the chapter and seals it for everyone.
@Observable
final class GatherSession: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    static let serviceType = "presents-join"

    nonisolated private enum Message: Codable, Sendable {
        case hello(name: String, avatar: Data?)
        case naming(String)
        case seal(RollInvite)
    }

    /// Friends whose phones are connected, by name, with their profile photo if they shared one.
    var people: [String: Data?] = [:]
    /// What the namer is typing, live, so everyone watches the chapter get its name.
    var liveName = ""
    var invite: RollInvite?

    var names: [String] { people.keys.sorted() }
    /// The phone with the lowest key among everyone connected names the chapter.
    var isNamer: Bool { connectedKeys.allSatisfy { myKey < $0 } }
    var namerName: String? {
        guard let key = ([myKey] + connectedKeys).min() else { return nil }
        return key == myKey ? me : keyToName[key]
    }

    @ObservationIgnored private let me: String
    @ObservationIgnored private let avatar: Data?
    @ObservationIgnored private let myKey: String
    @ObservationIgnored private let peerID: MCPeerID
    @ObservationIgnored private let session: MCSession
    @ObservationIgnored private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored private var browser: MCNearbyServiceBrowser?
    private var connectedKeys: [String] = []
    @ObservationIgnored private var keyToName: [String: String] = [:]

    init(name: String, avatar: Data?) {
        me = name.isEmpty ? "Friend" : name
        self.avatar = avatar
        myKey = UUID().uuidString
        // Display names cap at 63 bytes; the key rides in discovery info instead.
        peerID = MCPeerID(displayName: String(me.prefix(40)))
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    func start() {
        let advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: ["key": myKey], serviceType: Self.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        let session = session
        Task {
            try? await Task.sleep(for: .seconds(2))
            session.disconnect()
        }
    }

    func type(_ name: String) {
        liveName = name
        send(.naming(name))
    }

    /// The namer seals it for everyone connected. Returns the members, namer first.
    func seal(rollID: UUID, name: String, revealDate: Date, noticeTogether: Bool) -> [String] {
        let members = [me] + names
        let invite = RollInvite(rollID: rollID, name: name, revealDate: revealDate, members: members, noticeTogether: noticeTogether)
        send(.seal(invite))
        return members
    }

    private func send(_ message: Message) {
        guard !session.connectedPeers.isEmpty, let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    // MARK: Delegates (called off the main thread)

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let key = context.flatMap { String(data: $0, encoding: .utf8) }
        let name = peerID.displayName
        Task { @MainActor in
            if let key { self.keyToName[key] = name; self.pendingKeys[name] = key }
            // Being in the same room is the permission.
            invitationHandler(true, self.session)
        }
    }

    @ObservationIgnored private var pendingKeys: [String: String] = [:]

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard let theirKey = info?["key"] else { return }
        Task { @MainActor in
            self.keyToName[theirKey] = peerID.displayName
            self.pendingKeys[peerID.displayName] = theirKey
            // Only one side of each pair invites, so every pair connects once.
            guard self.myKey < theirKey, !self.session.connectedPeers.contains(peerID) else { return }
            browser.invitePeer(peerID, to: self.session, withContext: self.myKey.data(using: .utf8), timeout: 20)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let name = peerID.displayName
        Task { @MainActor in
            switch state {
            case .connected:
                if self.people[name] == nil { self.people[name] = .some(nil) }
                if let key = self.pendingKeys[name], !self.connectedKeys.contains(key) { self.connectedKeys.append(key) }
                if let data = try? JSONEncoder().encode(Message.hello(name: self.me, avatar: self.avatar)) {
                    try? session.send(data, toPeers: [peerID], with: .reliable)
                }
                if self.isNamer, !self.liveName.isEmpty { self.send(.naming(self.liveName)) }
            case .notConnected:
                self.people[name] = nil
                if let key = self.pendingKeys[name] { self.connectedKeys.removeAll { $0 == key } }
            default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
        let name = peerID.displayName
        Task { @MainActor in
            switch message {
            case .hello(_, let avatar):
                self.people[name] = .some(avatar)
            case .naming(let text):
                self.liveName = text
            case .seal(let invite):
                self.invite = invite
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension RollInvite {
    /// presents://join?i=<roll as base64url JSON>. Works without a server: the link carries the roll.
    var link: URL? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        let code = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "presents://join?i=\(code)")
    }

    init?(link url: URL) {
        guard url.scheme == "presents", url.host == "join",
              let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "i" })?.value
        else { return nil }
        var base64 = code.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let invite = try? JSONDecoder().decode(RollInvite.self, from: data) else { return nil }
        self = invite
    }
}
