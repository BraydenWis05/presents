import Foundation

/// Supabase project. The publishable key is meant to ship in the app; rules on the server
/// (supabase/setup.sql) decide what each phone can see.
nonisolated enum SupabaseConfig {
    static let url = URL(string: "https://muxavfuiplciknnekkxq.supabase.co")!
    static let key = "sb_publishable_qQxaLb6HSWWQO3tL7-DeCw_7FieL-OH"
}

/// Shared groups and sealed moments, over Supabase's REST APIs (no package needed).
/// Each phone signs in anonymously; being in a group's member list is what lets it read that group.
final class Cloud {
    static let shared = Cloud()

    nonisolated struct RemoteRoll: Codable, Sendable {
        var id: UUID
        var name: String
        var reveal_date: Date
    }

    nonisolated struct RemoteMember: Codable, Sendable {
        var roll_id: UUID
        var name: String
    }

    nonisolated struct RemoteMoment: Codable, Sendable {
        var id: UUID
        var roll_id: UUID
        var author: String
        var kind: String
        var caption: String
        var body: String
        var media_path: String?
        var thumb_path: String?
        var created_at: Date
        var hidden_at: Date?
    }

    private nonisolated struct Session: Codable, Sendable {
        var access_token: String
        var refresh_token: String
        var expires_at: Double?
    }

    private var session: Session? {
        get { UserDefaults.standard.data(forKey: "cloud.session").flatMap { try? JSONDecoder().decode(Session.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "cloud.session") }
    }

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "date \(s)"))
        }
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    // MARK: Auth

    private func token() async throws -> String {
        if let s = session, (s.expires_at ?? 0) > Date().timeIntervalSince1970 + 60 { return s.access_token }
        if let s = session, let fresh = try? await auth(path: "token?grant_type=refresh_token", body: ["refresh_token": s.refresh_token]) {
            session = fresh
            return fresh.access_token
        }
        let created = try await auth(path: "signup", body: [:])
        session = created
        return created.access_token
    }

    private func auth(path: String, body: [String: String]) async throws -> Session {
        var req = URLRequest(url: SupabaseConfig.url.appending(path: "auth/v1/").appending(path: path.components(separatedBy: "?")[0]))
        if path.contains("?"), var c = URLComponents(url: req.url!, resolvingAgainstBaseURL: false) {
            c.query = path.components(separatedBy: "?")[1]
            req.url = c.url
        }
        req.httpMethod = "POST"
        req.setValue(SupabaseConfig.key, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, data)
        return try JSONDecoder().decode(Session.self, from: data)
    }

    // MARK: Requests

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil,
                         contentType: String = "application/json", headers: [String: String] = [:], okIfExists: Bool = false) async throws -> Data {
        var c = URLComponents(url: SupabaseConfig.url.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        req.httpBody = body
        req.setValue(SupabaseConfig.key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 401 { session = nil }
        // Already there (another phone created the group, or this moment was sent before).
        if okIfExists, status == 409 { return data }
        try check(response, data)
        return data
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? ""])
        }
    }

    // MARK: Groups

    /// Idempotent: makes sure the group exists and this phone is in it.
    func ensure(rollID: UUID, name: String, revealDate: Date, me: String) async throws {
        let roll = RemoteRoll(id: rollID, name: name, reveal_date: revealDate)
        _ = try await request("rest/v1/rolls", method: "POST", body: try encoder.encode(roll),
                              headers: ["Prefer": "return=minimal"], okIfExists: true)
        _ = try await request("rest/v1/members", method: "POST", body: try encoder.encode(["roll_id": rollID.uuidString, "name": me]),
                              headers: ["Prefer": "return=minimal"], okIfExists: true)
    }

    func members(_ rollID: UUID) async throws -> [String] {
        let data = try await request("rest/v1/members", query: [.init(name: "roll_id", value: "eq.\(rollID)"), .init(name: "select", value: "roll_id,name")])
        return try decoder.decode([RemoteMember].self, from: data).map(\.name)
    }

    // MARK: Moments

    func moments(_ rollID: UUID) async throws -> [RemoteMoment] {
        let data = try await request("rest/v1/moments", query: [.init(name: "roll_id", value: "eq.\(rollID)"), .init(name: "select", value: "*")])
        return try decoder.decode([RemoteMoment].self, from: data)
    }

    func push(_ m: RemoteMoment, media: URL?, thumb: URL?) async throws {
        var m = m
        if let media, let data = try? Data(contentsOf: media) {
            let path = "\(m.roll_id)/\(media.lastPathComponent)"
            try await upload(path, data: data, type: Self.mime(media.pathExtension))
            m.media_path = path
        }
        if let thumb, let data = try? Data(contentsOf: thumb) {
            let path = "\(m.roll_id)/\(thumb.lastPathComponent)"
            try await upload(path, data: data, type: "image/jpeg")
            m.thumb_path = path
        }
        _ = try await request("rest/v1/moments", method: "POST", body: try encoder.encode(m),
                              headers: ["Prefer": "return=minimal"], okIfExists: true)
    }

    func hide(_ id: UUID, at date: Date) async throws {
        _ = try await request("rest/v1/moments", method: "PATCH", query: [.init(name: "id", value: "eq.\(id)")],
                              body: try encoder.encode(["hidden_at": date]), headers: ["Prefer": "return=minimal"])
    }

    func takeBack(_ id: UUID, paths: [String]) async throws {
        _ = try await request("rest/v1/moments", method: "DELETE", query: [.init(name: "id", value: "eq.\(id)")], headers: ["Prefer": "return=minimal"])
        for p in paths { _ = try? await request("storage/v1/object/moments/\(p)", method: "DELETE") }
    }

    // MARK: Files

    private func upload(_ path: String, data: Data, type: String) async throws {
        _ = try await request("storage/v1/object/moments/\(path)", method: "POST", body: data, contentType: type, headers: ["x-upsert": "true"])
    }

    func download(_ path: String) async throws -> Data {
        try await request("storage/v1/object/authenticated/moments/\(path)")
    }

    private static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "m4a": "audio/mp4"
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        default: "application/octet-stream"
        }
    }
}
