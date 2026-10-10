import ARKit
import AVFoundation
import Foundation
import RoomPlan

/// A scan kept on this phone: everything recorded, so it can be uploaded later, uploaded
/// again, or continued another day.
struct KeptScan: Codable, Identifiable, Hashable {
    var id: String
    /// The space it belongs to.
    var token: String
    var created: Date
    var updated: Date
    /// With a floor plan (RoomPlan ran beside the recording).
    var plan: Bool
    /// How long the video is so far, over all segments.
    var seconds: Double = 0
    /// Roughly how much surface was scanned, m².
    var area: Double = 0
    /// Rooms finished so far, and the names given to them.
    var rooms: Int = 0
    var names: [String?] = []
    /// Times it was scanned: 1, and one more for every time it was continued.
    var segments: Int = 0
    var uploaded: Date?
}

/// The scans kept on this phone, one folder each under Application Support/Scans:
///   meta.json     the KeptScan
///   walk.rgbd     depth and small photos (DepthLog), all segments in one file
///   walk.poses    the camera's pose per video frame (PoseLog), all segments
///   seg-<n>.mov   the video of each segment
///   rooms/<n>.json  RoomPlan's rooms (CapturedRoom, Apple's encoding)
///   world.map     ARKit's map of the place, to find it again when the scan is continued
enum ScanStore {
    static let root: URL = {
        var u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = URLResourceValues()
        v.isExcludedFromBackup = true   // big, and of no use on another phone
        try? u.setResourceValues(v)
        return u
    }()

    static func dir(_ s: KeptScan) -> URL { root.appendingPathComponent(s.id, isDirectory: true) }
    static func depth(_ dir: URL) -> URL { dir.appendingPathComponent("walk.rgbd") }
    static func poses(_ dir: URL) -> URL { dir.appendingPathComponent("walk.poses") }
    static func video(_ dir: URL, _ segment: Int) -> URL { dir.appendingPathComponent("seg-\(segment).mov") }
    static func worldMap(_ dir: URL) -> URL { dir.appendingPathComponent("world.map") }
    static func room(_ dir: URL, _ n: Int) -> URL { dir.appendingPathComponent("rooms/\(n).json") }

    static func new(token: String, plan: Bool) -> KeptScan {
        let s = KeptScan(id: "scan-\(Int(Date().timeIntervalSince1970))", token: token, created: Date(), updated: Date(), plan: plan)
        try? FileManager.default.createDirectory(at: dir(s).appendingPathComponent("rooms"), withIntermediateDirectories: true)
        return s
    }

    static func save(_ s: KeptScan) {
        try? JSONEncoder().encode(s).write(to: dir(s).appendingPathComponent("meta.json"), options: .atomic)
    }

    static func delete(_ s: KeptScan) {
        try? FileManager.default.removeItem(at: dir(s))
    }

    /// The kept scans of a space, newest first. A folder without meta.json is a scan that
    /// was never finished (the app was closed in the middle); it is cleared away.
    static func list(token: String) -> [KeptScan] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var out = [KeptScan]()
        for d in dirs {
            if let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")), let s = try? JSONDecoder().decode(KeptScan.self, from: data) {
                if s.token == token { out.append(s) }
            } else if let made = try? d.resourceValues(forKeys: [.creationDateKey]).creationDate, Date().timeIntervalSince(made) > 6 * 3600 {
                try? FileManager.default.removeItem(at: d)
            }
        }
        return out.sorted { $0.updated > $1.updated }
    }

    static func bytes(_ s: KeptScan) -> Int64 {
        let files = FileManager.default.enumerator(at: dir(s), includingPropertiesForKeys: [.fileSizeKey])
        var n: Int64 = 0
        while let f = files?.nextObject() as? URL {
            n += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return n
    }

    static func rooms(_ s: KeptScan) -> [CapturedRoom] {
        (0..<s.rooms).compactMap { n in
            (try? Data(contentsOf: room(dir(s), n))).flatMap { try? JSONDecoder().decode(CapturedRoom.self, from: $0) }
        }
    }

    /// Queues everything of a kept scan for upload. The scan stays on the phone.
    static func upload(_ s: KeptScan, to space: SavedSpace) async throws {
        let d = dir(s), fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        let tmp = fm.temporaryDirectory
        guard fm.fileExists(atPath: depth(d).path) else {
            throw APIError(message: "No depth was recorded, so there is nothing to build a model from.")
        }
        var files = [URL]()

        // The scan's own file first: the server starts on it when it arrives.
        let rooms = rooms(s)
        if !rooms.isEmpty {
            let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)
            let json = tmp.appendingPathComponent("scan-\(stamp).roomplan")
            try ScanExport.json(structure, names: s.names).write(to: json)
            files.append(json)
            let usdz = tmp.appendingPathComponent("scan-\(stamp).usdz")
            if (try? structure.export(to: usdz)) != nil { files.append(usdz) }
        } else {
            let note = tmp.appendingPathComponent("scan-\(stamp).freescan")
            try JSONSerialization.data(withJSONObject: ["version": 1, "seconds": Int(s.seconds)]).write(to: note)
            files.append(note)
        }

        // The uploader takes its files away, so it gets links; the originals stay here.
        // Poses and video are named alike: that is how the server pairs them.
        func link(_ from: URL, _ name: String) throws {
            guard fm.fileExists(atPath: from.path) else { return }
            let to = tmp.appendingPathComponent(name)
            try? fm.removeItem(at: to)
            do { try fm.linkItem(at: from, to: to) } catch { try fm.copyItem(at: from, to: to) }
            files.append(to)
        }
        let video = tmp.appendingPathComponent("walk-\(stamp).mov")
        let segments = (0..<s.segments).map { ScanStore.video(d, $0) }.filter { fm.fileExists(atPath: $0.path) }
        let joined = segments.count > 1 ? await join(segments, to: video) : false
        if joined || segments.count == 1 { try link(poses(d), "walk-\(stamp).poses") }
        try link(depth(d), "walk-\(stamp).rgbd")
        if joined { files.append(video) } else if segments.count == 1 { try link(segments[0], "walk-\(stamp).mov") }

        let list = files
        try await Task.detached {   // cutting a long video into chunks takes a moment
            for f in list { try Uploader.shared.enqueue(space, file: f, filename: f.lastPathComponent) }
        }.value
        await Uploader.shared.resume()
        var done = s
        done.uploaded = Date()
        save(done)
    }

    /// The segments' videos end to end as one file, without re-encoding. Each takes
    /// exactly its own length, which is what the pose track's times count on.
    private static func join(_ segments: [URL], to out: URL) async -> Bool {
        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return false }
        var at = CMTime.zero, sounds = 0
        for (i, url) in segments.enumerated() {
            let asset = AVURLAsset(url: url)
            guard let length = try? await asset.load(.duration), let vt = try? await asset.loadTracks(withMediaType: .video).first else { return false }
            let range = CMTimeRange(start: .zero, duration: length)
            guard (try? cv.insertTimeRange(range, of: vt, at: at)) != nil else { return false }
            if i == 0, let t = try? await vt.load(.preferredTransform) { cv.preferredTransform = t }
            if let sound = try? await asset.loadTracks(withMediaType: .audio).first {
                if (try? ca.insertTimeRange(range, of: sound, at: at)) != nil { sounds += 1 }
            }
            at = at + length
        }
        if sounds == 0 { comp.removeTrack(ca) }
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { return false }
        try? FileManager.default.removeItem(at: out)
        ex.outputURL = out
        ex.outputFileType = .mov
        await ex.export()
        return ex.status == .completed
    }

    /// How long a video file is, s.
    static func length(_ url: URL) async -> Double {
        ((try? await AVURLAsset(url: url).load(.duration))?.seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
    }
}
