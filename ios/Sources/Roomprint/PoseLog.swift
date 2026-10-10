import ARKit
import Foundation

/// Where the camera was for every frame of the walk video, so the worker can paint the 3D
/// model from the video's full-resolution frames instead of the depth file's small photos
/// (worker/views.py).
///
/// File format (.poses), little-endian: the magic "RPP1", u32 header length, header JSON
/// {iw, ih} (camera image size), then one 88-byte record per video frame:
///   f64 t (the frame's time in the video, s), f32 fx, fy, cx, cy (intrinsics at camera
///   image size), f32[16] camera to world (column-major, ARKit axes).
final class PoseLog: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "roomprint.poses", qos: .utility)
    private var handle: FileHandle?
    private var buffer = Data()
    private var count = 0

    init(url: URL) {
        self.url = url
    }

    /// Call for each frame that went into the video, with its time there.
    func add(_ frame: ARFrame, time: TimeInterval) {
        let K = frame.camera.intrinsics
        let T = frame.camera.transform
        let size = frame.camera.imageResolution
        var rec = Data(capacity: 88)
        withUnsafeBytes(of: time.bitPattern.littleEndian) { rec.append(contentsOf: $0) }
        let floats: [Float] = [K[0][0], K[1][1], K[2][0], K[2][1]] + (0..<4).flatMap { col in (0..<4).map { T[col][$0] } }
        for v in floats { withUnsafeBytes(of: v.bitPattern.littleEndian) { rec.append(contentsOf: $0) } }
        queue.async { [self] in
            if handle == nil {
                let head = (try? JSONSerialization.data(withJSONObject: ["iw": Int(size.width), "ih": Int(size.height)])) ?? Data()
                var start = Data("RPP1".utf8)
                withUnsafeBytes(of: UInt32(head.count).littleEndian) { start.append(contentsOf: $0) }
                start.append(head)
                FileManager.default.createFile(atPath: url.path, contents: start)
                handle = try? FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
            }
            buffer.append(rec)
            count += 1
            if buffer.count >= 88 * 150 { flush() }
        }
    }

    private func flush() {
        try? handle?.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    /// Writes what is left and closes the file; nil if the video had no frames.
    func finish() async -> URL? {
        await withCheckedContinuation { (k: CheckedContinuation<URL?, Never>) in
            queue.async { [self] in
                flush()
                try? handle?.close()
                handle = nil
                k.resume(returning: count > 0 ? url : nil)
            }
        }
    }
}
