import Foundation

/// An invite link the app knows: the server it lives on and its token.
struct SavedSpace: Codable, Identifiable, Hashable {
    var base: String
    var token: String
    var name: String
    /// Proof that this phone made the space: needed to delete it or its files.
    var ownerKey: String?
    var id: String { token }

    var viewerURL: URL { URL(string: "\(base)/s/\(token)")! }
    var api: String { "\(base)/api/s/\(token)" }
}

struct Summary: Decodable {
    struct Meta: Decodable { let id: String; let name: String }
    struct Status: Decodable { let state: String; let step: String; let progress: Double; let error: String?; let updated: String? }
    struct Clip: Decodable { let id: String; let filename: String; let bytes: Int }
    let meta: Meta
    let status: Status
    let clips: [Clip]
    let has_space: Bool
    let has_mesh: Bool?
    let has_textured: Bool?
    let splat: String?

    var busy: Bool { ["queued", "processing"].contains(status.state) }
    /// Changes whenever the viewer has something new to show.
    var shown: String { "\(has_space) \(has_mesh ?? false) \(has_textured ?? false) \(splat ?? "")" }
}

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// What tells this phone apart on the server's list of every space: a number the app makes
/// up for itself the first time, and the phone's model. Nothing of the person.
enum Device {
    static let id: String = {
        if let known = UserDefaults.standard.string(forKey: "device") { return known }
        let made = UUID().uuidString.lowercased()
        UserDefaults.standard.set(made, forKey: "device")
        return made
    }()

    /// The hardware's own name for the model, such as "iPhone16,1".
    static let model: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }()
}

/// The Roomprint web API (web/server.ts). Uploads go up in 8 MB chunks through Uploader.
enum API {
    static let defaultBase = Secrets.baseURL
    static let chunk = 8 * 1024 * 1024

    /// roomprint://u/<token>, https://host/u/<token>, https://host/s/<token>, or a bare token.
    static func parseInvite(_ text: String) -> (base: String, token: String)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isToken(t) { return (defaultBase, t) }
        guard let url = URL(string: t) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if url.scheme == "roomprint" {
            // roomprint://u/<token>: host is "u"
            guard let token = parts.last, isToken(token) else { return nil }
            return (defaultBase, token)
        }
        guard let scheme = url.scheme, let host = url.host, parts.count == 2, ["u", "s"].contains(parts[0]),
              isToken(parts[1]) else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return ("\(scheme)://\(host)\(port)", parts[1])
    }

    static func isToken(_ s: String) -> Bool {
        (8...64).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    static func request(_ url: String, method: String = "GET", json: Any? = nil, body: Data? = nil,
                        headers: [String: String] = [:]) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.timeoutInterval = 120
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            req.httpBody = body
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func errorText(_ data: Data, _ code: Int) -> String {
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["error"] as? String) ?? "server said \(code)"
    }

    /// A new space of our own; the server only allows it with the app's secret.
    static func createSpace(name: String) async throws -> SavedSpace {
        var req = URLRequest(url: URL(string: "\(defaultBase)/api/spaces")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(Secrets.appSecret)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "device": Device.id, "model": Device.model])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, let n = obj["name"] as? String else {
            throw APIError(message: errorText(data, code))
        }
        return SavedSpace(base: defaultBase, token: token, name: n, ownerKey: obj["owner"] as? String)
    }

    /// The owner key for a space this app made before owner keys existed; nil if the space
    /// already has an owner (then this phone did not make it).
    static func claim(_ s: SavedSpace) async throws -> String? {
        let (data, code) = try await request("\(s.api)/claim", method: "POST", json: [String: Any](),
                                             headers: ["Authorization": "Bearer \(Secrets.appSecret)"])
        if code == 409 || code == 403 { return nil }
        guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(message: errorText(data, code))
        }
        return obj["owner"] as? String
    }

    /// Says which phone made a space that was made before the app told its phone apart.
    static func tellDevice(_ s: SavedSpace) async throws {
        let (data, code) = try await request("\(s.api)/device", method: "POST", json: ["device": Device.id, "model": Device.model],
                                             headers: ["X-Owner-Key": s.ownerKey ?? ""])
        guard code == 200 || code == 404 else { throw APIError(message: errorText(data, code)) }
    }

    /// Deletes the whole space from the server, for good.
    static func deleteSpace(_ s: SavedSpace) async throws {
        let (data, code) = try await request(s.api, method: "DELETE", headers: ["X-Owner-Key": s.ownerKey ?? ""])
        guard code == 200 || code == 404 else { throw APIError(message: errorText(data, code)) }
    }

    /// Deletes one uploaded file from the server, for good.
    static func deleteClip(_ s: SavedSpace, id: String) async throws {
        let (data, code) = try await request("\(s.api)/clips/\(id)", method: "DELETE", headers: ["X-Owner-Key": s.ownerKey ?? ""])
        guard code == 200 || code == 404 else { throw APIError(message: errorText(data, code)) }
    }

    static func summary(base: String, token: String) async throws -> Summary {
        let (data, code) = try await request("\(base)/api/s/\(token)")
        guard code == 200 else { throw APIError(message: code == 404 ? "This link is not valid." : errorText(data, code)) }
        return try JSONDecoder().decode(Summary.self, from: data)
    }
}
