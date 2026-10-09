import Foundation
import UIKit

/// Uploads that carry on after the app is closed or the phone is locked.
///
/// Each file is cut into 8 MB chunk files under Application Support/Uploads/<job>/ and every
/// chunk is handed to a background URLSession as its own PUT, so iOS uploads them while the
/// app is suspended and relaunches it when they are done. The server takes chunks in any
/// order and more than once, and starts processing a scan by itself once its .roomplan
/// file is complete, so nothing has to wait for the app to come back.
///
/// A job is only lost when its space is gone (404); everything else is retried.
final class Uploader: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = Uploader()
    static let sessionID = "com.p4ulcristian.roomprint.upload"

    struct Job: Codable {
        var api: String          // https://host/api/s/<token>
        var token: String
        var filename: String
        var bytes: Int
        var roomName: String?
        var clip: String?        // the server's clip id, once registered
    }

    /// Bytes sent and total per space token, for the space page while uploads run.
    @Published private(set) var progress: [String: (sent: Int64, total: Int64)] = [:]

    /// Handed over by the app delegate when iOS wakes us for finished background uploads.
    var backgroundCompletion: (() -> Void)?

    private let root: URL
    private let queue = DispatchQueue(label: "roomprint.uploader")
    private var sentByTask: [Int: Int64] = [:]       // bytes each running task has sent
    private var inFlightByToken: [String: Int64] = [:] // the same, summed per space
    private var resuming = false
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.allowsCellularAccess = true
        cfg.timeoutIntervalForResource = 7 * 24 * 3600
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return URLSession(configuration: cfg, delegate: self, delegateQueue: q)
    }()

    override init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Uploads", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = session   // reconnect to tasks iOS kept running while the app was gone
    }

    // MARK: Queueing

    /// Cut `file` into chunks and queue them. The file is moved away (it is a temporary
    /// file of ours), so the caller must not use it afterwards.
    func enqueue(_ space: SavedSpace, file: URL, filename: String, roomName: String? = nil) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { return }
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fh = try FileHandle(forReadingFrom: file)
        defer { try? fh.close() }
        var offset = 0
        while offset < size {
            let piece = fh.readData(ofLength: API.chunk)
            if piece.isEmpty { break }
            try piece.write(to: dir.appendingPathComponent("\(offset).chunk"))
            offset += piece.count
        }
        let job = Job(api: space.api, token: space.token, filename: filename, bytes: size, roomName: roomName)
        try JSONEncoder().encode(job).write(to: dir.appendingPathComponent("job.json"))
        try? FileManager.default.removeItem(at: file)
    }

    /// Register new jobs with the server and make sure every chunk has a running task.
    /// Called after queueing, at launch and whenever the app comes to the front.
    func resume() async {
        guard claim() else { return }
        defer { queue.sync { resuming = false } }
        let running = Set(await session.allTasks.compactMap(\.taskDescription))
        for dir in jobDirs() {
            guard var job = load(dir) else { continue }
            let chunks = chunkFiles(dir)
            if chunks.isEmpty { try? FileManager.default.removeItem(at: dir); continue }
            if job.clip == nil {
                do {
                    job.clip = try await register(job)
                    try JSONEncoder().encode(job).write(to: dir.appendingPathComponent("job.json"))
                } catch let e as APIError where e.message == "gone" {
                    try? FileManager.default.removeItem(at: dir); continue
                } catch {
                    continue   // offline: try again next time
                }
            }
            for (offset, file) in chunks where !running.contains(desc(dir, offset)) {
                start(job, dir: dir, offset: offset, file: file)
            }
        }
        refreshProgress()
    }

    /// Drops every queued upload of a space (it was deleted): nothing more of it is sent.
    func cancel(token: String) async {
        let doomed = Set(jobDirs().filter { load($0)?.token == token }.map(\.lastPathComponent))
        // Files first, so a cancelled task finds no chunk to retry.
        for name in doomed { try? FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
        for t in await session.allTasks {
            if let d = t.taskDescription?.split(separator: "/").first, doomed.contains(String(d)) { t.cancel() }
        }
        refreshProgress()
    }

    private func claim() -> Bool {
        queue.sync {
            if resuming { return false }
            resuming = true
            return true
        }
    }

    private func register(_ job: Job) async throws -> String {
        var body: [String: Any] = ["filename": job.filename, "bytes": job.bytes]
        if let r = job.roomName, !r.isEmpty { body["room_name"] = r }
        let (data, code) = try await API.request("\(job.api)/clips", method: "POST", json: body)
        if code == 404 { throw APIError(message: "gone") }
        guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else { throw APIError(message: API.errorText(data, code)) }
        return id
    }

    private func start(_ job: Job, dir: URL, offset: Int, file: URL, after delay: TimeInterval = 0) {
        guard let clip = job.clip, let url = URL(string: "\(job.api)/clips/\(clip)?offset=\(offset)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let task = session.uploadTask(with: req, fromFile: file)
        task.taskDescription = desc(dir, offset)
        if delay > 0 { task.earliestBeginDate = Date().addingTimeInterval(delay) }
        task.resume()
    }

    // MARK: Files

    private func desc(_ dir: URL, _ offset: Int) -> String { "\(dir.lastPathComponent)/\(offset)" }

    private func jobDirs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    }

    private func load(_ dir: URL) -> Job? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("job.json")) else { return nil }
        return try? JSONDecoder().decode(Job.self, from: data)
    }

    private func chunkFiles(_ dir: URL) -> [(Int, URL)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { f in
            guard f.pathExtension == "chunk", let o = Int(f.deletingPathExtension().lastPathComponent) else { return nil }
            return (o, f)
        }.sorted { $0.0 < $1.0 }
    }

    /// Sent and total bytes per space, from the chunks still on disk and the running tasks.
    private func refreshProgress() {
        var out: [String: (sent: Int64, total: Int64)] = [:]
        for dir in jobDirs() {
            guard let job = load(dir) else { continue }
            let left = chunkFiles(dir).reduce(Int64(0)) { a, c in
                a + ((try? FileManager.default.attributesOfItem(atPath: c.1.path)[.size] as? NSNumber)?.int64Value ?? 0)
            }
            var p = out[job.token] ?? (0, 0)
            p.total += Int64(job.bytes)
            p.sent += Int64(job.bytes) - left
            out[job.token] = p
        }
        // add what the running tasks have sent of the chunks still on disk
        for (token, extra) in queue.sync(execute: { inFlightByToken }) {
            if var p = out[token] { p.sent = min(p.total, p.sent + extra); out[token] = p }
        }
        DispatchQueue.main.async { self.progress = out }
    }
}

extension Uploader: URLSessionTaskDelegate, URLSessionDataDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let (dir, _) = parse(task), let job = load(dir) else { return }
        queue.sync {
            let before = sentByTask[task.taskIdentifier] ?? 0
            sentByTask[task.taskIdentifier] = totalBytesSent
            inFlightByToken[job.token, default: 0] += totalBytesSent - before
        }
        refreshProgress()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let (dir, offset) = parse(task) else { return }
        let job = load(dir)
        queue.sync {
            let sent = sentByTask.removeValue(forKey: task.taskIdentifier) ?? 0
            if let t = job?.token { inFlightByToken[t, default: 0] -= sent }
        }
        let chunk = dir.appendingPathComponent("\(offset).chunk")
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if error == nil && code == 200 {
            try? FileManager.default.removeItem(at: chunk)
            if chunkFiles(dir).isEmpty { try? FileManager.default.removeItem(at: dir) }
        } else if code == 404 || job == nil {
            try? FileManager.default.removeItem(at: dir)   // the space or its clip is gone
        } else if let job, FileManager.default.fileExists(atPath: chunk.path) {
            start(job, dir: dir, offset: offset, file: chunk, after: 30)   // network or server trouble: again soon
        }
        refreshProgress()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }

    private func parse(_ task: URLSessionTask) -> (URL, Int)? {
        guard let d = task.taskDescription?.split(separator: "/"), d.count == 2, let o = Int(d[1]) else { return nil }
        return (root.appendingPathComponent(String(d[0]), isDirectory: true), o)
    }
}

/// Hands iOS's "your background uploads finished" wake-up to the uploader.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == Uploader.sessionID else { return completionHandler() }
        Uploader.shared.backgroundCompletion = completionHandler
    }
}
