import ARKit
import CoreImage
import Foundation

/// Keeps the LiDAR depth seen during a scan, so the worker can fuse it into a coloured
/// 3D model of the real rooms (worker/fuse.py). RoomPlan reads the same depth to find
/// walls and then drops it; here a few frames a second are kept.
///
/// File format (.rgbd), little-endian, one record per kept frame after the magic "RPD1":
///   u32 header length, header JSON, depth (zlib/raw deflate, Float16 metres, w*h),
///   confidence (raw deflate, UInt8 0-2, w*h), JPEG of the camera image.
/// Header: t (s since the first record), w, h (depth size), iw, ih (camera image size),
///   K (3x3 intrinsics at camera image size, row-major), T (camera to world, 4x4
///   column-major, ARKit axes), jw, jh (JPEG size), dz, cz, jz (byte lengths).
final class DepthLog: @unchecked Sendable {
    static let interval: TimeInterval = 0.2   // 5 frames a second
    static let jpegWidth: CGFloat = 640

    let url: URL
    private let queue = DispatchQueue(label: "roomprint.depth", qos: .utility)
    private let ci = CIContext()
    private var handle: FileHandle?
    private var busy = false     // one frame in flight at most; later ones are skipped
    private var first: TimeInterval?
    private var last: TimeInterval = 0
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }

    /// A scan continued later goes on in the same file: `offset` is how long it already is.
    private let offset: TimeInterval

    init(url: URL, offset: TimeInterval = 0) {
        self.url = url
        self.offset = offset
    }

    /// Called for every polled frame; keeps one every `interval` while tracking is good.
    func offer(_ frame: ARFrame) {
        guard frame.timestamp - last >= Self.interval, case .normal = frame.camera.trackingState,
              let depth = frame.sceneDepth ?? frame.smoothedSceneDepth else { return }
        let skip: Bool = lock.withLock {
            if busy { return true }
            busy = true
            return false
        }
        if skip { return }
        last = frame.timestamp
        if first == nil { first = frame.timestamp }

        // Copy what is needed now; the camera image is only held until the JPEG is made.
        let t = offset + frame.timestamp - (first ?? frame.timestamp)
        let d = Self.float16(depth.depthMap)
        let c = depth.confidenceMap.map(Self.bytes) ?? Data(count: d.w * d.h)
        let image = frame.capturedImage
        let iw = CVPixelBufferGetWidth(image), ih = CVPixelBufferGetHeight(image)
        let K = frame.camera.intrinsics
        let T = frame.camera.transform

        queue.async { [self] in
            defer { lock.withLock { busy = false } }
            let s = Self.jpegWidth / CGFloat(iw)
            let small = CIImage(cvPixelBuffer: image).transformed(by: CGAffineTransform(scaleX: s, y: s))
            guard let jpeg = ci.jpegRepresentation(of: small, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                   options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]),
                  let dz = try? (d.data as NSData).compressed(using: .zlib) as Data,
                  let cz = try? (c as NSData).compressed(using: .zlib) as Data else { return }
            let header: [String: Any] = [
                "t": t, "w": d.w, "h": d.h, "iw": iw, "ih": ih,
                "K": [K[0][0], K[1][0], K[2][0], K[0][1], K[1][1], K[2][1], K[0][2], K[1][2], K[2][2]],
                "T": (0..<4).flatMap { col in (0..<4).map { T[col][$0] } },
                "jw": Int((CGFloat(iw) * s).rounded()), "jh": Int((CGFloat(ih) * s).rounded()),
                "dz": dz.count, "cz": cz.count, "jz": jpeg.count,
            ]
            guard let hj = try? JSONSerialization.data(withJSONObject: header) else { return }
            do {
                if handle == nil {
                    if !FileManager.default.fileExists(atPath: url.path) {
                        FileManager.default.createFile(atPath: url.path, contents: Data("RPD1".utf8))
                    }
                    handle = try FileHandle(forWritingTo: url)
                    try handle?.seekToEnd()
                }
                var n = UInt32(hj.count).littleEndian
                try handle?.write(contentsOf: Data(bytes: &n, count: 4))
                try handle?.write(contentsOf: hj)
                try handle?.write(contentsOf: dz)
                try handle?.write(contentsOf: cz)
                try handle?.write(contentsOf: jpeg)
                lock.withLock { _count += 1 }
            } catch {
                print("depth log: \(error)")
            }
        }
    }

    /// Waits for the last frame and closes the file; nil if it holds no depth at all.
    func finish() async -> URL? {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                try? handle?.close()
                handle = nil
                k.resume()
            }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return size > 4 ? url : nil
    }

    private static func float16(_ pb: CVPixelBuffer) -> (data: Data, w: Int, h: Int) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        var out = [Float16](repeating: 0, count: w * h)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return (Data(), w, h) }
        for y in 0..<h {
            let src = (base + y * row).assumingMemoryBound(to: Float32.self)
            for x in 0..<w { out[y * w + x] = Float16(src[x]) }
        }
        return (out.withUnsafeBytes { Data($0) }, w, h)
    }

    private static func bytes(_ pb: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return Data(count: w * h) }
        var out = Data(capacity: w * h)
        for y in 0..<h { out.append(Data(bytes: base + y * row, count: w)) }
        return out
    }
}
