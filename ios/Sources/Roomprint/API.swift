import Foundation

/// An invite link the app knows: the server it lives on and its token.
struct SavedSpace: Codable, Identifiable, Hashable {
    var base: String
    var token: String
    var name: String
    var id: String { token }

    var viewerURL: URL { URL(string: "\(base)/s/\(token)")! }
    var api: String { "\(base)/api/s/\(token)" }
}

struct Summary: Decodable {
    struct Meta: Decodable { let id: String; let name: String }
    struct Status: Decodable { let state: String; let step: String; let progress: Double; let error: String? }
    struct Clip: Decodable { let id: String; let filename: String; let bytes: Int }
    let meta: Meta
    let status: Status
    let clips: [Clip]
    let has_space: Bool
}

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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

    static func request(_ url: String, method: String = "GET", json: Any? = nil, body: Data? = nil) async throws -> (Data, Int) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
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
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, let n = obj["name"] as? String else {
            throw APIError(message: errorText(data, code))
        }
        return SavedSpace(base: defaultBase, token: token, name: n)
    }

    static func summary(base: String, token: String) async throws -> Summary {
        let (data, code) = try await request("\(base)/api/s/\(token)")
        guard code == 200 else { throw APIError(message: code == 404 ? "This link is not valid." : errorText(data, code)) }
        return try JSONDecoder().decode(Summary.self, from: data)
    }
}
