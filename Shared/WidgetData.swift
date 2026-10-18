import Foundation

/// Shared between the app and the home screen widget through the app group container.
nonisolated enum AppGroup {
    /// Must match both .entitlements files in Config/. Change it when the app gets a real team and bundle ID.
    static let id = "group.com.braydenwisniewski.presents"
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }
}

/// What the widget shows. The app writes it whenever the roll or "who's nearby" changes.
nonisolated struct WidgetSnapshot: Codable, Sendable {
    var rollName: String
    var revealDate: Date
    var momentCount: Int
    var isReadyToOpen: Bool
    /// Friends nearby right now. Empty means the group isn't together.
    var togetherWith: [String]
    var updatedAt = Date()

    static let fileName = "widget.json"
    /// Pre-rendered, blurred stack of the roll so the widget never touches real media.
    static let stackImageName = "stack.png"

    static func load() -> WidgetSnapshot? {
        guard let url = AppGroup.container?.appending(path: fileName),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let url = AppGroup.container?.appending(path: Self.fileName),
              let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear() {
        guard let dir = AppGroup.container else { return }
        try? FileManager.default.removeItem(at: dir.appending(path: fileName))
        try? FileManager.default.removeItem(at: dir.appending(path: stackImageName))
    }

    static var stackImageURL: URL? { AppGroup.container?.appending(path: stackImageName) }
}

nonisolated enum DeepLink {
    static let capture = URL(string: "presents://capture")!
    static let open = URL(string: "presents://open")!
}

nonisolated extension Date {
    /// "Oct 16 · 2026"
    var stamp: String {
        "\(formatted(.dateTime.month(.abbreviated).day())) · \(formatted(.dateTime.year()))"
    }
}

nonisolated enum Together {
    /// "Isabelle", "Isabelle & Maya", "Isabelle, Maya & 2 more"
    static func names(_ people: [String]) -> String {
        switch people.count {
        case 0: return ""
        case 1: return people[0]
        case 2: return "\(people[0]) & \(people[1])"
        case 3: return "\(people[0]), \(people[1]) & \(people[2])"
        default: return "\(people[0]), \(people[1]) & \(people.count - 2) more"
        }
    }
}
