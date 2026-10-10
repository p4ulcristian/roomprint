import ARKit
import SceneKit
import SwiftUI

/// The scan as it stands, on the phone, while scanning: a rough coloured model built from
/// the same depth and camera frames the recorder keeps, so the gaps show before anything
/// is uploaded. The server's model is finer, but it has the same holes.
///
/// Three things come out of it:
///   model    the coloured model, for the small inset and the full-screen look
///   overlay  dots over the camera image on what has been scanned (orange: seen too little)
///   hint     a line of advice (slow down, move closer, ...)
@MainActor
final class LiveScan: ObservableObject {
    @Published private(set) var hint: String?
    @Published private(set) var cells = 0

    let model = SCNScene()
    let overlay = SCNScene()
    /// The camera the inset looks through; it circles the model slowly.
    let insetCamera = SCNNode()
    /// The camera of the full-screen look, turned by hand.
    let fullCamera = SCNNode()
    /// Set by the views, so the overlay matches the screen and the model is cut for the right eye.
    weak var overlayView: SCNView?
    weak var fullView: SCNView?

    private let grid = VoxelGrid()
    private let cloud = SCNNode(), good = SCNNode(), thin = SCNNode(), phone = SCNNode()
    /// The overlay's camera: the phone's own.
    let overlayCamera = SCNNode()
    private var centre = SIMD3<Float>(0, 0, 0)
    private var radius: Float = 1.5
    private var turn: Float = 0.6
    private var lastFrame: TimeInterval = 0, lastSample: TimeInterval = 0, lastModel: TimeInterval = 0, lastOverlay: TimeInterval = 0
    private var before: (p: SIMD3<Float>, f: SIMD3<Float>, t: TimeInterval)?
    private var hintSince: TimeInterval = 0

    init() {
        model.background.contents = UIColor(red: 0.055, green: 0.075, blue: 0.1, alpha: 1)
        for cam in [insetCamera, fullCamera] {
            cam.camera = SCNCamera()
            cam.camera?.zNear = 0.05
            cam.camera?.zFar = 300
            cam.camera?.fieldOfView = 50
            model.rootNode.addChildNode(cam)
        }
        let dot = SCNSphere(radius: 0.09)
        dot.firstMaterial?.lightingModel = .constant
        dot.firstMaterial?.diffuse.contents = UIColor.systemBlue
        phone.geometry = dot
        model.rootNode.addChildNode(cloud)
        model.rootNode.addChildNode(phone)

        overlay.background.contents = UIColor.clear
        overlayCamera.camera = SCNCamera()
        good.opacity = 0.4
        thin.opacity = 0.75
        for n in [overlayCamera, good, thin] { overlay.rootNode.addChildNode(n) }
    }

    /// Called for every frame the recorder polls. `recording` is false while the scan is paused.
    func frame(_ frame: ARFrame, recording: Bool) {
        let t = frame.timestamp
        let T = frame.camera.transform
        let eye = SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)

        // The overlay's camera is the phone's own, so its dots sit on the real surfaces.
        if let size = overlayView?.bounds.size, size.width > 0 {
            overlayCamera.camera?.projectionTransform = SCNMatrix4(frame.camera.projectionMatrix(for: .portrait, viewportSize: size, zNear: 0.05, zFar: 50))
            overlayCamera.simdTransform = frame.camera.viewMatrix(for: .portrait).inverse
        }
        phone.simdPosition = eye
        turn += Float(min(0.1, max(0, t - lastFrame))) * 0.2
        lastFrame = t
        insetCamera.simdPosition = insetEye
        insetCamera.simdLook(at: centre)

        guard t - lastSample >= 0.2 else { return }
        lastSample = t
        var centreDepth: Float?
        if case .normal = frame.camera.trackingState, let s = VoxelGrid.sample(frame) {
            centreDepth = s.centre
            if recording { grid.add(s) }
        }
        coach(frame, eye: eye, centreDepth: centreDepth, recording: recording)

        let looking = fullView?.window != nil
        if t - lastModel >= (looking ? 0.3 : 1) {
            lastModel = t
            let from = looking ? fullView?.pointOfView?.presentation.simdWorldPosition ?? insetEye : insetEye
            grid.model(from: from) { [weak self] shot in self?.show(shot) }
        }
        if !looking, overlayView?.window != nil, t - lastOverlay >= 1 {
            lastOverlay = t
            grid.coverage(from: eye) { [weak self] shot in self?.show(shot) }
        }
    }

    /// Puts the full-screen camera where the inset's is now; call when that view opens.
    func openFull() {
        fullCamera.simdPosition = insetEye
        fullCamera.simdLook(at: centre)
        lastModel = 0
    }

    var lookAt: SCNVector3 { SCNVector3(centre.x, centre.y, centre.z) }

    private var insetEye: SIMD3<Float> {
        centre + radius * SIMD3<Float>(sin(turn) * 1.15, 1.3, cos(turn) * 1.15)
    }

    private func show(_ shot: VoxelGrid.Model) {
        cloud.geometry = Self.points(shot.positions, colours: shot.colours, count: shot.count, size: VoxelGrid.size * 1.3, tint: nil)
        cells = shot.total
        if shot.count > 0 {
            centre = shot.centre
            radius = max(1, shot.radius)
        }
    }

    private func show(_ shot: VoxelGrid.Coverage) {
        good.geometry = Self.points(shot.good, colours: nil, count: shot.goodCount, size: 0.012, tint: UIColor(red: 0.75, green: 1, blue: 0.95, alpha: 1))
        thin.geometry = Self.points(shot.thin, colours: nil, count: shot.thinCount, size: 0.03, tint: .systemOrange)
    }

    private static func points(_ positions: Data, colours: Data?, count: Int, size: Float, tint: UIColor?) -> SCNGeometry? {
        guard count > 0 else { return nil }
        let stride = MemoryLayout<SIMD3<Float>>.stride
        var sources = [SCNGeometrySource(data: positions, semantic: .vertex, vectorCount: count, usesFloatComponents: true,
                                         componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride)]
        if let colours {
            sources.append(SCNGeometrySource(data: colours, semantic: .color, vectorCount: count, usesFloatComponents: true,
                                             componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride))
        }
        let element = SCNGeometryElement(data: nil, primitiveType: .point, primitiveCount: count, bytesPerIndex: 4)
        element.pointSize = CGFloat(size)
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 30
        let g = SCNGeometry(sources: sources, elements: [element])
        g.firstMaterial?.lightingModel = .constant
        g.firstMaterial?.diffuse.contents = tint ?? UIColor.white
        return g
    }

    // MARK: advice

    private func coach(_ frame: ARFrame, eye: SIMD3<Float>, centreDepth: Float?, recording: Bool) {
        let t = frame.timestamp
        let T = frame.camera.transform
        let forward = -SIMD3<Float>(T.columns.2.x, T.columns.2.y, T.columns.2.z)
        var speed: Float = 0, spin: Float = 0
        if let b = before, t > b.t {
            let dt = Float(t - b.t)
            speed = simd_length(eye - b.p) / dt
            spin = acos(max(-1, min(1, simd_dot(forward, b.f)))) / dt
        }
        before = (eye, forward, t)

        var now: String?
        switch frame.camera.trackingState {
        case .normal:
            if speed > 0.9 || spin > 1.4 { now = "Slow down" }
            else if let l = frame.lightEstimate, l.ambientIntensity < 120 { now = "It is dark here. Turn on a light if you can." }
            else if let d = centreDepth, d > 4 { now = "Move closer" }
            else if let d = centreDepth, d < 0.3 { now = "Too close. Step back a little." }
        case .limited(.excessiveMotion): now = "Slow down"
        case .limited(.insufficientFeatures): now = "Too dark or too plain here. Point at something with detail."
        case .limited(.relocalizing): now = "Lost my place. Point back at something already scanned."
        case .limited(.initializing): now = nil
        default: now = "Lost my place. Hold still for a moment."
        }
        if !recording { now = nil }
        // A line stays up for a moment after its reason has gone, so it can be read.
        if let now {
            hintSince = t
            if hint != now { hint = now }
        } else if hint != nil, t - hintSince > 1.2 || !recording {
            hint = nil
        }
    }
}

/// The scanned surfaces in 4 cm cells: where each is, its colour, which way it was seen
/// from and how often. Everything here runs on its own queue.
final class VoxelGrid: @unchecked Sendable {
    static let size: Float = 0.04
    /// Samples a cell needs before it counts as seen well: about two close looks.
    static let enough: UInt16 = 25
    private static let limit = 1_000_000

    /// One depth frame, thinned out: points in the camera's own axes, with their colours.
    struct Sample {
        var points: [SIMD3<Float>]
        var colours: [SIMD3<Float>]
        var T: simd_float4x4
        var centre: Float?
    }
    struct Model {
        var positions: Data, colours: Data, count: Int, total: Int
        var centre: SIMD3<Float>, radius: Float
    }
    struct Coverage {
        var good: Data, goodCount: Int, thin: Data, thinCount: Int
    }

    private let queue = DispatchQueue(label: "roomprint.live", qos: .userInitiated)
    private var index: [Int64: Int32] = [:]
    private var pos: [SIMD3<Float>] = [], col: [SIMD3<Float>] = [], dir: [SIMD3<Float>] = []
    private var hits: [UInt16] = []
    private let lock = NSLock()
    private var waiting = 0

    func add(_ s: Sample) {
        // If the phone falls behind, frames are dropped rather than queued up.
        let behind: Bool = lock.withLock {
            if waiting >= 2 { return true }
            waiting += 1
            return false
        }
        if behind { return }
        queue.async { [self] in
            defer { lock.withLock { waiting -= 1 } }
            let eye = SIMD3<Float>(s.T.columns.3.x, s.T.columns.3.y, s.T.columns.3.z)
            for i in s.points.indices {
                let p4 = s.T * SIMD4<Float>(s.points[i], 1)
                let p = SIMD3<Float>(p4.x, p4.y, p4.z)
                let g = (p / Self.size).rounded(.down)
                let key = (Int64(g.x) & 0x1FFFFF) | ((Int64(g.y) & 0x1FFFFF) << 21) | ((Int64(g.z) & 0x1FFFFF) << 42)
                let to = simd_normalize(eye - p)
                if let j = index[key] {
                    let k = Int(j)
                    let w = 1 / (Float(min(hits[k], 30)) + 1)
                    pos[k] += (p - pos[k]) * w
                    col[k] += (s.colours[i] - col[k]) * w
                    dir[k] += (to - dir[k]) * w
                    if hits[k] < .max { hits[k] += 1 }
                } else if pos.count < Self.limit {
                    index[key] = Int32(pos.count)
                    pos.append(p)
                    col.append(s.colours[i])
                    dir.append(to)
                    hits.append(1)
                }
            }
        }
    }

    /// The coloured model as seen from `eye`: surfaces facing away are left out, so a room
    /// is looked into through its ceiling and its near walls, like a doll's house.
    func model(from eye: SIMD3<Float>, then: @escaping @MainActor (Model) -> Void) {
        queue.async { [self] in
            var p = [SIMD3<Float>](), c = [SIMD3<Float>]()
            p.reserveCapacity(pos.count / 2)
            c.reserveCapacity(pos.count / 2)
            var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
            for i in pos.indices where hits[i] >= 2 {
                lo = simd_min(lo, pos[i])
                hi = simd_max(hi, pos[i])
                if simd_dot(dir[i], eye - pos[i]) > 0 {
                    p.append(pos[i])
                    c.append(col[i])
                }
            }
            let shot = Model(positions: Self.data(p), colours: Self.data(c), count: p.count, total: pos.count,
                             centre: (lo + hi) / 2, radius: simd_length(hi - lo) / 2)
            Task { @MainActor in then(shot) }
        }
    }

    /// What has been scanned, for the dots over the camera image: seen well, and seen too little.
    func coverage(from eye: SIMD3<Float>, then: @escaping @MainActor (Coverage) -> Void) {
        queue.async { [self] in
            var good = [SIMD3<Float>](), thin = [SIMD3<Float>]()
            for i in pos.indices where hits[i] >= 2 {
                let to = pos[i] - eye
                // only what is near and turned towards the phone; the rest would show through walls
                guard simd_length_squared(to) < 36, simd_dot(dir[i], to) < 0 else { continue }
                if hits[i] >= Self.enough { good.append(pos[i]) } else { thin.append(pos[i]) }
            }
            let shot = Coverage(good: Self.data(good), goodCount: good.count, thin: Self.data(thin), thinCount: thin.count)
            Task { @MainActor in then(shot) }
        }
    }

    private static func data(_ a: [SIMD3<Float>]) -> Data {
        a.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Every second depth pixel that the LiDAR trusts, with the camera image's colour there.
    static func sample(_ frame: ARFrame) -> Sample? {
        guard let depth = frame.sceneDepth ?? frame.smoothedSceneDepth else { return nil }
        let dm = depth.depthMap, cm = depth.confidenceMap, image = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(image) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(dm, .readOnly)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        if let cm { CVPixelBufferLockBaseAddress(cm, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(dm, .readOnly)
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            if let cm { CVPixelBufferUnlockBaseAddress(cm, .readOnly) }
        }
        guard let dbase = CVPixelBufferGetBaseAddress(dm),
              let ybase = CVPixelBufferGetBaseAddressOfPlane(image, 0)?.assumingMemoryBound(to: UInt8.self),
              let cbase = CVPixelBufferGetBaseAddressOfPlane(image, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let w = CVPixelBufferGetWidth(dm), h = CVPixelBufferGetHeight(dm), drow = CVPixelBufferGetBytesPerRow(dm)
        let iw = CVPixelBufferGetWidthOfPlane(image, 0), ih = CVPixelBufferGetHeightOfPlane(image, 0)
        let yrow = CVPixelBufferGetBytesPerRowOfPlane(image, 0), crow = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        let conf = cm.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confRow = cm.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let K = frame.camera.intrinsics
        let sx = Float(w) / Float(iw), sy = Float(h) / Float(ih)
        let fx = K[0][0] * sx, fy = K[1][1] * sy, cx = K[2][0] * sx, cy = K[2][1] * sy

        var points = [SIMD3<Float>](), colours = [SIMD3<Float>]()
        points.reserveCapacity(w * h / 4)
        colours.reserveCapacity(w * h / 4)
        for y in stride(from: 1, to: h, by: 2) {
            let drowp = (dbase + y * drow).assumingMemoryBound(to: Float32.self)
            let crowp = conf.map { ($0 + y * confRow).assumingMemoryBound(to: UInt8.self) }
            let iy = min(ih - 1, y * ih / h)
            for x in stride(from: 1, to: w, by: 2) {
                let d = drowp[x]
                guard d.isFinite, d > 0.15, d < 5 else { continue }
                let trust = crowp?[x] ?? 2
                if trust == 0 || (trust == 1 && d > 3) { continue }
                let ix = min(iw - 1, x * iw / w)
                let lum = Float(ybase[iy * yrow + ix])
                let ci = (iy / 2) * crow + (ix / 2) * 2
                let cb = Float(cbase[ci]) - 128, cr = Float(cbase[ci + 1]) - 128
                let rgb = simd_clamp(SIMD3<Float>(lum + 1.402 * cr, lum - 0.344 * cb - 0.714 * cr, lum + 1.772 * cb) / 255,
                                     SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
                colours.append(rgb * rgb)   // SceneKit takes vertex colours as linear light
                // image axes (x right, y down, z ahead) -> ARKit camera axes (y up, looking down -z)
                points.append(SIMD3<Float>((Float(x) - cx) / fx * d, -(Float(y) - cy) / fy * d, -d))
            }
        }
        let mid = (dbase + (h / 2) * drow).assumingMemoryBound(to: Float32.self)[w / 2]
        return Sample(points: points, colours: colours, T: frame.camera.transform, centre: mid.isFinite && mid > 0 ? mid : nil)
    }
}
