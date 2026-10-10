import ARKit
import SceneKit
import SwiftUI

/// The scan as it stands, on the phone, while scanning, so the gaps show before anything
/// is uploaded. The surfaces are ARKit's own live mesh; their colours come from the same
/// depth and camera frames the recorder keeps (VoxelGrid). The server's model is finer,
/// but it has the same holes.
///
/// What comes out of it:
///   model  the coloured model: a map from above in the corner, and the full-screen look
///   tint   the same surfaces as a wireframe for the camera view: blue where scanned well,
///          red where seen too little; the camera image shows through
///   hint   a line of advice (slow down, move closer, ...)
///   arrow  which way to turn for the nearest gap that is out of sight
///
/// Where the AR session gives no mesh (RoomPlan may keep it to itself), the model is
/// drawn as points from the depth alone.
@MainActor
final class LiveScan: ObservableObject {
    @Published private(set) var hint: String?
    /// Surface scanned so far, m² (rough).
    @Published private(set) var area: Double = 0
    /// The way to a gap that is out of sight, as an angle on the screen (0 is up, clockwise).
    @Published private(set) var arrow: Double?
    /// The map keeps to the few metres around the phone and turns with it; off, it shows the whole scan.
    var follow = true

    let model = SCNScene()
    /// The scene of the camera view: the wireframe sits on the real surfaces.
    let tint = SCNScene()
    /// Looks straight down on the model, for the map in the corner.
    let mapCamera = SCNNode()
    /// The camera of the full-screen look, turned by hand.
    let fullCamera = SCNNode()
    weak var fullView: SCNView?

    private typealias Piece = (model: SCNNode, tint: SCNNode, lo: SIMD3<Float>, hi: SIMD3<Float>)
    private let grid = VoxelGrid()
    private let cloud = SCNNode(), edges = SCNNode(), phone = SCNNode()
    private let wallsSeen = SCNNode(), wallsMapped = SCNNode()
    private var replayed = false
    private var cloudBox: (lo: SIMD3<Float>, hi: SIMD3<Float>)?
    private var heading = SIMD3<Float>(0, 0, -1)
    private var began: TimeInterval?
    private var lastCount: TimeInterval = 0, lastGap: TimeInterval = 0, lastTick: TimeInterval = 0
    private var counted = 0
    private var gap: SIMD3<Float>?, gapBefore: SIMD3<Float>?
    private var lost = false
    private let tick = UIImpactFeedbackGenerator(style: .soft), warn = UINotificationFeedbackGenerator()
    private var parts: [UUID: Piece] = [:]
    private var built: [UUID: ObjectIdentifier] = [:]
    private var builtAt: [UUID: TimeInterval] = [:]
    private var anchors: [ARMeshAnchor] = []
    private var meshing = false
    private var centre = SIMD3<Float>(0, 0, 0)
    private var radius: Float = 1.5      // half the model's diagonal
    private var reach: Float = 1.5       // half its larger side on the floor
    private var lastSample: TimeInterval = 0, lastModel: TimeInterval = 0, lastMesh: TimeInterval = 0
    private var before: (p: SIMD3<Float>, f: SIMD3<Float>, t: TimeInterval)?
    private var hintSince: TimeInterval = 0

    init() {
        model.background.contents = UIColor(red: 0.055, green: 0.075, blue: 0.1, alpha: 1)
        for cam in [mapCamera, fullCamera] {
            cam.camera = SCNCamera()
            cam.camera?.zNear = 0.05
            cam.camera?.zFar = 400
            model.rootNode.addChildNode(cam)
        }
        mapCamera.camera?.usesOrthographicProjection = true
        fullCamera.camera?.fieldOfView = 50

        // Where the phone is: a dot with a short beam the way it points.
        let dot = SCNSphere(radius: 1)
        let bar = SCNBox(width: 0.7, height: 0.7, length: 2.2, chamferRadius: 0.3)
        let beam = SCNNode(geometry: bar)
        beam.position = SCNVector3(0, 0, -1.6)
        for g in [dot, bar] as [SCNGeometry] {
            g.firstMaterial?.lightingModel = .constant
            g.firstMaterial?.diffuse.contents = UIColor.systemBlue
        }
        phone.geometry = dot
        phone.addChildNode(beam)
        for n in [cloud, edges, phone, wallsMapped] { model.rootNode.addChildNode(n) }
        tint.rootNode.addChildNode(wallsSeen)
    }

    /// Called for every frame the recorder polls. `recording` is false while the scan is paused.
    func frame(_ frame: ARFrame, recording: Bool) {
        let t = frame.timestamp
        let T = frame.camera.transform
        let eye = SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)
        let forward = -SIMD3<Float>(T.columns.2.x, T.columns.2.y, T.columns.2.z)

        phone.simdPosition = eye
        phone.eulerAngles = SCNVector3(0, atan2(-forward.x, -forward.z), 0)
        phone.simdScale = SIMD3<Float>(repeating: follow ? 0.1 : max(0.07, reach * 0.045))
        // The map looks straight down. Following, the way the phone points is up on it.
        let flat = SIMD3<Float>(forward.x, 0, forward.z)
        if simd_length(flat) > 0.25 { heading = simd_normalize(simd_mix(heading, simd_normalize(flat), SIMD3<Float>(repeating: 0.12))) }
        let up = follow ? heading : SIMD3<Float>(0, 0, -1), back = SIMD3<Float>(0, 1, 0)
        let over = (follow ? SIMD3<Float>(eye.x, centre.y, eye.z) : centre) + SIMD3<Float>(0, 100, 0)
        mapCamera.simdTransform = simd_float4x4(SIMD4<Float>(simd_cross(up, back), 0), SIMD4<Float>(up, 0), SIMD4<Float>(back, 0), SIMD4<Float>(over, 1))
        mapCamera.camera?.orthographicScale = Double(follow ? 2.6 : max(1.2, reach * 1.15))
        if began == nil, recording { began = t }

        guard t - lastSample >= 0.2 else { return }
        lastSample = t
        var centreDepth: Float?
        if case .normal = frame.camera.trackingState, let s = VoxelGrid.sample(frame) {
            centreDepth = s.centre
            if recording { grid.add(s) }
        }
        coach(frame, eye: eye, forward: forward, centreDepth: centreDepth, recording: recording)

        if recording, t - lastMesh >= 0.5 {
            lastMesh = t
            meshes(frame, eye: eye)
        }
        if t - lastCount >= 1 {
            lastCount = t
            count(t, recording: recording)
        }
        steer(frame, eye: eye, forward: forward, recording: recording)
        let looking = fullView?.window != nil
        if parts.isEmpty || replayed, t - lastModel >= (looking ? 0.3 : 1) {
            lastModel = t
            let above = centre + SIMD3<Float>(0, 100, 0)
            let from = looking ? fullView?.pointOfView?.presentation.simdWorldPosition ?? above : above
            grid.model(from: from, oldOnly: !parts.isEmpty) { [weak self] shot in self?.show(shot) }
        }
    }

    /// The numbers, and a tick in the hand for every bit of new surface: scanning something
    /// new feels different from going over the same place again.
    private func count(_ t: TimeInterval, recording: Bool) {
        let n = grid.cells
        let m2 = Double(n) * Double(VoxelGrid.size * VoxelGrid.size)
        if abs(m2 - area) >= 0.5 { area = m2 }
        if recording, n - counted >= 300, t - lastTick > 0.35 {
            lastTick = t
            tick.impactOccurred(intensity: 0.6)
        }
        counted = n
    }

    /// Finds the nearest sizeable gap now and then, and points to it while it is out of sight.
    private func steer(_ frame: ARFrame, eye: SIMD3<Float>, forward: SIMD3<Float>, recording: Bool) {
        let t = frame.timestamp
        if recording, !parts.isEmpty, let began, t - began > 20, t - lastGap >= 2 {
            lastGap = t
            grid.gap(near: eye) { [weak self] found in
                guard let self else { return }
                // only a gap found twice running: the mesh's edge flickers where it is still growing
                if let found, let b = self.gapBefore, simd_length(found - b) < 0.7 { self.gap = found } else { self.gap = nil }
                self.gapBefore = found
            }
        }
        var angle: Double?
        if recording, let gap, simd_dot(simd_normalize(gap - eye), forward) < 0.45 {
            let v = frame.camera.viewMatrix(for: .portrait) * SIMD4<Float>(gap, 1)
            angle = (Double(atan2(v.x, v.y)) * 8).rounded() / 8
        }
        if angle != arrow { arrow = angle }
    }

    /// Brings back what an earlier session of this scan saw, so its coverage shows when the
    /// scan is continued. It is drawn as points: ARKit only meshes what it sees this time.
    func replay(_ url: URL) {
        replayed = true
        let grid = grid
        Task.detached(priority: .utility) { VoxelGrid.read(url) { grid.addOld($0) } }
    }

    /// RoomPlan's walls, doors and windows so far, drawn into the camera view and the map.
    func plan(_ surfaces: [(transform: simd_float4x4, size: SIMD3<Float>, opening: Bool)]) {
        for n in wallsSeen.childNodes + wallsMapped.childNodes { n.removeFromParentNode() }
        for s in surfaces {
            let seen = SCNBox(width: CGFloat(s.size.x), height: CGFloat(s.size.y), length: 0.03, chamferRadius: 0)
            seen.firstMaterial?.lightingModel = .constant
            seen.firstMaterial?.diffuse.contents = s.opening ? UIColor.systemBlue : UIColor.white
            seen.firstMaterial?.transparency = s.opening ? 0.3 : 0.14
            seen.firstMaterial?.isDoubleSided = true
            seen.firstMaterial?.writesToDepthBuffer = false
            let a = SCNNode(geometry: seen)
            a.simdTransform = s.transform
            wallsSeen.addChildNode(a)
            let mapped = SCNBox(width: CGFloat(s.size.x), height: CGFloat(s.size.y), length: 0.09, chamferRadius: 0)
            mapped.firstMaterial?.lightingModel = .constant
            mapped.firstMaterial?.diffuse.contents = s.opening ? UIColor.systemBlue : UIColor.white
            let b = SCNNode(geometry: mapped)
            b.simdTransform = s.transform
            wallsMapped.addChildNode(b)
        }
    }

    /// Sets up the full-screen look; call when that view opens. Brings every surface up to
    /// date and marks the edges of the holes.
    func openFull() {
        fullCamera.simdPosition = centre + radius * SIMD3<Float>(0.95, 1.25, 0.95)
        fullCamera.simdLook(at: centre)
        lastModel = 0
        if !anchors.isEmpty {
            update(anchors, at: lastMesh)
            grid.outline { [weak self] lines, count in self?.edges.geometry = Self.lines(lines, count: count) }
        }
    }

    var lookAt: SCNVector3 { SCNVector3(centre.x, centre.y, centre.z) }

    // MARK: surfaces

    /// Takes ARKit's mesh as it is now: the pieces nearest the phone that have changed.
    private func meshes(_ frame: ARFrame, eye: SIMD3<Float>) {
        let now = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !now.isEmpty else { return }
        anchors = now
        guard !meshing else { return }
        if !replayed { cloud.geometry = nil }
        let here = Set(now.map(\.identifier))
        let gone = parts.keys.filter { !here.contains($0) }
        for id in gone {
            parts[id]?.model.removeFromParentNode()
            parts[id]?.tint.removeFromParentNode()
            parts[id] = nil
            built[id] = nil
            builtAt[id] = nil
        }
        if !gone.isEmpty { grid.forget(gone) }

        // New pieces first, then the nearest. A piece near the phone is redone every two
        // seconds even if its shape has not changed: its colours do, as it is seen more.
        let t = frame.timestamp
        func away(_ a: ARMeshAnchor) -> Float {
            let c = a.transform.columns.3
            return simd_length_squared(SIMD3<Float>(c.x, c.y, c.z) - eye)
        }
        func rank(_ a: ARMeshAnchor) -> Float { built[a.identifier] == nil ? -1 : away(a) }
        let due = now.filter {
            built[$0.identifier] != ObjectIdentifier($0.geometry) || (t - (builtAt[$0.identifier] ?? 0) > 2 && away($0) < 30)
        }.sorted { rank($0) < rank($1) }
        if !due.isEmpty { update(Array(due.prefix(16)), at: t) }
    }

    private func update(_ list: [ARMeshAnchor], at t: TimeInterval) {
        meshing = true
        for a in list {
            built[a.identifier] = ObjectIdentifier(a.geometry)
            builtAt[a.identifier] = t
        }
        grid.mesh(list) { [weak self] done in
            guard let self else { return }
            self.meshing = false
            for p in done { self.show(p) }
            self.frameModel()
        }
    }

    private func show(_ p: VoxelGrid.Part) {
        var part: Piece
        if let have = parts[p.id] {
            part = have
        } else {
            part = (SCNNode(), SCNNode(), p.lo, p.hi)
            model.rootNode.addChildNode(part.model)
            tint.rootNode.addChildNode(part.tint)
        }
        // The model is looked at from outside: faces turned away are not drawn, so a room
        // is seen into through its ceiling and near walls, like a doll's house.
        let solid = Self.surface(p, colours: p.colours)
        solid?.firstMaterial?.cullMode = .back
        part.model.geometry = solid
        part.tint.geometry = Self.wire(p)
        part.lo = p.lo
        part.hi = p.hi
        parts[p.id] = part
    }

    private func frameModel() {
        guard !parts.isEmpty else { return }
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for p in parts.values {
            lo = simd_min(lo, p.lo)
            hi = simd_max(hi, p.hi)
        }
        if let c = cloudBox {
            lo = simd_min(lo, c.lo)
            hi = simd_max(hi, c.hi)
        }
        fit(lo, hi)
    }

    private func fit(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) {
        centre = (lo + hi) / 2
        radius = max(1, simd_length(hi - lo) / 2)
        reach = max(1, max(hi.x - lo.x, hi.z - lo.z) / 2)
    }

    private func show(_ shot: VoxelGrid.Model) {
        guard parts.isEmpty || replayed else { return }
        cloud.geometry = Self.points(shot)
        guard shot.count > 0 else { return }
        cloudBox = (shot.lo, shot.hi)
        if parts.isEmpty { fit(shot.lo, shot.hi) } else { frameModel() }
    }

    private static func source(_ data: Data, _ semantic: SCNGeometrySource.Semantic, count: Int) -> SCNGeometrySource {
        SCNGeometrySource(data: data, semantic: semantic, vectorCount: count, usesFloatComponents: true,
                          componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
    }

    private static func surface(_ p: VoxelGrid.Part, colours: Data) -> SCNGeometry? {
        guard p.vertices > 0, p.faces > 0 else { return nil }
        let element = SCNGeometryElement(data: p.indices, primitiveType: .triangles, primitiveCount: p.faces, bytesPerIndex: 4)
        let g = SCNGeometry(sources: [source(p.positions, .vertex, count: p.vertices), source(colours, .color, count: p.vertices)], elements: [element])
        g.firstMaterial?.lightingModel = .constant
        return g
    }

    /// The surface as a wireframe: every triangle on its own, textured with its three edges.
    private static func wire(_ p: VoxelGrid.Part) -> SCNGeometry? {
        guard p.corners > 0 else { return nil }
        let uv = SCNGeometrySource(data: p.wireEdges, semantic: .texcoord, vectorCount: p.corners, usesFloatComponents: true,
                                   componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0, dataStride: 8)
        let element = SCNGeometryElement(data: nil, primitiveType: .triangles, primitiveCount: p.corners / 3, bytesPerIndex: 4)
        let g = SCNGeometry(sources: [source(p.wire, .vertex, count: p.corners), source(p.wireTints, .color, count: p.corners), uv], elements: [element])
        let m = g.firstMaterial
        m?.lightingModel = .constant
        m?.diffuse.contents = edgeImage
        m?.diffuse.mipFilter = .linear
        m?.blendMode = .alpha
        m?.writesToDepthBuffer = false
        return g
    }

    /// A triangle's three edges as glowing white lines on nothing: corners at (0, ½), (1, 0)
    /// and (1, 1), the same whichever way up the image is taken. The colour comes from the vertices.
    private static let edgeImage: UIImage = {
        let n: CGFloat = 128
        return UIGraphicsImageRenderer(size: CGSize(width: n, height: n), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false; return f }()).image { ctx in
            let c = ctx.cgContext
            c.move(to: CGPoint(x: 0, y: n / 2))
            c.addLine(to: CGPoint(x: n, y: 0))
            c.addLine(to: CGPoint(x: n, y: n))
            c.closePath()
            let path = c.path!
            for (width, alpha) in [(26.0, 0.10), (14.0, 0.22), (6.0, 1.0)] {
                c.addPath(path)
                c.setLineWidth(width)
                c.setStrokeColor(UIColor(white: 1, alpha: alpha).cgColor)
                c.strokePath()
            }
        }
    }()

    private static func points(_ shot: VoxelGrid.Model) -> SCNGeometry? {
        guard shot.count > 0 else { return nil }
        let element = SCNGeometryElement(data: nil, primitiveType: .point, primitiveCount: shot.count, bytesPerIndex: 4)
        element.pointSize = CGFloat(VoxelGrid.size * 1.6)
        element.minimumPointScreenSpaceRadius = 1.5
        element.maximumPointScreenSpaceRadius = 40
        let g = SCNGeometry(sources: [source(shot.positions, .vertex, count: shot.count), source(shot.colours, .color, count: shot.count)], elements: [element])
        g.firstMaterial?.lightingModel = .constant
        return g
    }

    private static func lines(_ data: Data, count: Int) -> SCNGeometry? {
        guard count > 0 else { return nil }
        let index = Array(0..<UInt32(count)).withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: index, primitiveType: .line, primitiveCount: count / 2, bytesPerIndex: 4)
        let g = SCNGeometry(sources: [source(data, .vertex, count: count)], elements: [element])
        g.firstMaterial?.lightingModel = .constant
        g.firstMaterial?.diffuse.contents = UIColor.systemOrange
        return g
    }

    // MARK: advice

    private func coach(_ frame: ARFrame, eye: SIMD3<Float>, forward: SIMD3<Float>, centreDepth: Float?, recording: Bool) {
        let t = frame.timestamp
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
        var isLost = false
        if case .limited(let why) = frame.camera.trackingState, case .relocalizing = why { isLost = true }
        if case .notAvailable = frame.camera.trackingState { isLost = true }
        if isLost, !lost, recording { warn.notificationOccurred(.warning) }
        lost = isLost
        // A line stays up for a moment after its reason has gone, so it can be read.
        if let now {
            hintSince = t
            if hint != now { hint = now }
        } else if hint != nil, t - hintSince > 1.2 || !recording {
            hint = nil
        }
    }
}

/// What the depth frames have seen, in 4 cm cells: each cell's colour, which way it was
/// seen from and how often. ARKit's mesh is coloured from it. Everything here runs on its
/// own queue.
final class VoxelGrid: @unchecked Sendable {
    static let size: Float = 0.04
    /// Samples a cell needs before it counts as seen well: a close look or two.
    static let enough: UInt16 = 12
    private static let limit = 1_000_000
    private static let unseen = SIMD3<Float>(0.12, 0.13, 0.15)   // model colour where no depth has landed yet
    private static let fine = SIMD3<Float>(0.1, 0.5, 1), thin = SIMD3<Float>(1, 0.08, 0.1)   // the wireframe: blue done, red not yet

    /// One depth frame, thinned out: points in the camera's own axes, with their colours.
    struct Sample {
        var points: [SIMD3<Float>]
        var colours: [SIMD3<Float>]
        var T: simd_float4x4
        var centre: Float?
    }
    /// The cells as points, for when there is no mesh.
    struct Model {
        var positions: Data, colours: Data, count: Int
        var lo: SIMD3<Float>, hi: SIMD3<Float>
    }
    /// One piece of ARKit's mesh in world axes, with a colour and a tint per vertex.
    struct Part {
        var id: UUID
        var positions: Data, colours: Data, indices: Data
        var vertices: Int, faces: Int
        /// The same triangles with corners of their own, for the wireframe: place, tint and edge texture place.
        var wire: Data, wireTints: Data, wireEdges: Data, corners: Int
        var lo: SIMD3<Float>, hi: SIMD3<Float>
    }
    private struct Edge: Hashable {
        let a: Int64, b: Int64
    }

    private let queue = DispatchQueue(label: "roomprint.live", qos: .userInitiated)
    private var index: [Int64: Int32] = [:]
    private var pos: [SIMD3<Float>] = [], col: [SIMD3<Float>] = [], dir: [SIMD3<Float>] = []
    private var hits: [UInt16] = []
    private var old: [Bool] = []          // seen in an earlier session of a scan that is being continued
    private var shapes: [UUID: (pos: [SIMD3<Float>], idx: [UInt32], lo: SIMD3<Float>, hi: SIMD3<Float>)] = [:]
    private let lock = NSLock()
    private var waiting = 0
    private var _cells = 0
    /// Cells seen so far.
    var cells: Int { lock.withLock { _cells } }

    private static func key(_ p: SIMD3<Float>, cell: Float) -> Int64 {
        let g = (p / cell).rounded(.down)
        return (Int64(g.x) & 0x1FFFFF) | ((Int64(g.y) & 0x1FFFFF) << 21) | ((Int64(g.z) & 0x1FFFFF) << 42)
    }

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
            take(s, old: false)
        }
    }

    /// A frame of an earlier session, read back from its depth file.
    func addOld(_ s: Sample) {
        queue.sync { take(s, old: true) }
    }

    private func take(_ s: Sample, old was: Bool) {
        let eye = SIMD3<Float>(s.T.columns.3.x, s.T.columns.3.y, s.T.columns.3.z)
        for i in s.points.indices {
            let p4 = s.T * SIMD4<Float>(s.points[i], 1)
            let p = SIMD3<Float>(p4.x, p4.y, p4.z)
            let k = Self.key(p, cell: Self.size)
            let to = simd_normalize(eye - p)
            if let j = index[k] {
                let c = Int(j)
                let w = 1 / (Float(min(hits[c], 30)) + 1)
                pos[c] += (p - pos[c]) * w
                col[c] += (s.colours[i] - col[c]) * w
                dir[c] += (to - dir[c]) * w
                if hits[c] < .max { hits[c] += 1 }
            } else if pos.count < Self.limit {
                index[k] = Int32(pos.count)
                pos.append(p)
                col.append(s.colours[i])
                dir.append(to)
                hits.append(1)
                old.append(was)
            }
        }
        let n = pos.count
        lock.withLock { _cells = n }
    }

    /// The cell a mesh vertex lies in, or failing that one right next to it: ARKit smooths
    /// its surface, so a vertex can sit a few centimetres off the raw depth.
    private func cell(at p: SIMD3<Float>) -> Int? {
        if let j = index[Self.key(p, cell: Self.size)] { return Int(j) }
        for axis in 0..<3 {
            for step in [Self.size, -Self.size] {
                var q = p
                q[axis] += step
                if let j = index[Self.key(q, cell: Self.size)] { return Int(j) }
            }
        }
        return nil
    }

    /// Pieces of ARKit's mesh, coloured from the cells.
    func mesh(_ anchors: [ARMeshAnchor], then: @escaping @MainActor ([Part]) -> Void) {
        queue.async { [self] in
            var out = [Part]()
            for a in anchors {
                let g = a.geometry
                let n = g.vertices.count, faces = g.faces.count, corners = faces * 3
                guard g.faces.indexCountPerPrimitive == 3, n > 0, faces > 0 else { continue }
                let base = g.vertices.buffer.contents() + g.vertices.offset
                var p = [SIMD3<Float>](), c = [SIMD3<Float>](), t = [SIMD3<Float>]()
                p.reserveCapacity(n)
                c.reserveCapacity(n)
                t.reserveCapacity(n)
                var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
                for i in 0..<n {
                    let v = (base + i * g.vertices.stride).assumingMemoryBound(to: Float.self)
                    let w4 = a.transform * SIMD4<Float>(v[0], v[1], v[2], 1)
                    let w = SIMD3<Float>(w4.x, w4.y, w4.z)
                    p.append(w)
                    lo = simd_min(lo, w)
                    hi = simd_max(hi, w)
                    if let k = cell(at: w) {
                        c.append(col[k])
                        t.append(hits[k] >= Self.enough ? Self.fine : Self.thin)
                    } else {
                        c.append(Self.unseen)
                        t.append(Self.thin)
                    }
                }
                var idx = [UInt32](repeating: 0, count: corners)
                let raw = g.faces.buffer.contents()
                if g.faces.bytesPerIndex == 4 {
                    let src = raw.assumingMemoryBound(to: UInt32.self)
                    for i in 0..<corners { idx[i] = src[i] }
                } else {
                    let src = raw.assumingMemoryBound(to: UInt16.self)
                    for i in 0..<corners { idx[i] = UInt32(src[i]) }
                }
                shapes[a.identifier] = (p, idx, lo, hi)
                var wp = [SIMD3<Float>](), wt = [SIMD3<Float>](), we = [SIMD2<Float>]()
                wp.reserveCapacity(corners)
                wt.reserveCapacity(corners)
                we.reserveCapacity(corners)
                let edge = [SIMD2<Float>(0, 0.5), SIMD2<Float>(1, 0), SIMD2<Float>(1, 1)]
                for i in 0..<corners where Int(idx[i]) < n {
                    wp.append(p[Int(idx[i])])
                    wt.append(t[Int(idx[i])])
                    we.append(edge[i % 3])
                }
                let whole = wp.count == corners   // a bad index would shift every triangle after it
                out.append(Part(id: a.identifier, positions: Self.data(p), colours: Self.data(c),
                                indices: idx.withUnsafeBufferPointer { Data(buffer: $0) }, vertices: n, faces: faces,
                                wire: Self.data(wp), wireTints: Self.data(wt), wireEdges: we.withUnsafeBufferPointer { Data(buffer: $0) },
                                corners: whole ? corners : 0, lo: lo, hi: hi))
            }
            let done = out
            Task { @MainActor in then(done) }
        }
    }

    func forget(_ ids: [UUID]) {
        queue.async { [self] in
            for id in ids { shapes[id] = nil }
        }
    }

    /// Every edge of every triangle, with its two ends; an edge is named by where its ends
    /// are (to 1 cm), so the same edge in two of ARKit's pieces is one edge.
    private func eachEdge(near: SIMD3<Float>? = nil, within: Float = 0, _ body: (Edge, SIMD3<Float>, SIMD3<Float>) -> Void) {
        for s in shapes.values {
            if let near, simd_length(simd_max(simd_max(s.lo - near, near - s.hi), SIMD3<Float>(repeating: 0))) > within { continue }
            let keys = s.pos.map { Self.key($0 + 0.005, cell: 0.01) }
            var f = 0
            while f + 2 < s.idx.count {
                for (u, v) in [(0, 1), (1, 2), (2, 0)] {
                    let i = Int(s.idx[f + u]), j = Int(s.idx[f + v])
                    if i < keys.count, j < keys.count, keys[i] != keys[j] {
                        body(Edge(a: min(keys[i], keys[j]), b: max(keys[i], keys[j])), s.pos[i], s.pos[j])
                    }
                }
                f += 3
            }
        }
    }

    /// The open edges of the mesh, as line ends: an edge with a triangle on one side only
    /// borders a hole.
    func outline(then: @escaping @MainActor (Data, Int) -> Void) {
        queue.async { [self] in
            var seen = [Edge: UInt8]()
            seen.reserveCapacity(shapes.values.reduce(0) { $0 + $1.idx.count } / 2)
            eachEdge { e, _, _ in seen[e] = min(2, (seen[e] ?? 0) + 1) }
            var ends = [SIMD3<Float>]()
            eachEdge { e, p, q in
                if seen[e] == 1 {
                    ends.append(p)
                    ends.append(q)
                }
            }
            let data = Self.data(ends), count = ends.count
            Task { @MainActor in then(data, count) }
        }
    }

    /// The middle of the biggest gap within a few steps of `eye`: where the most open
    /// edge lies in one half-metre block. Nil if there is none worth walking to.
    func gap(near eye: SIMD3<Float>, then: @escaping @MainActor (SIMD3<Float>?) -> Void) {
        queue.async { [self] in
            var seen = [Edge: UInt8]()
            eachEdge(near: eye, within: 4.5) { e, _, _ in seen[e] = min(2, (seen[e] ?? 0) + 1) }
            var blocks = [Int64: (length: Float, sum: SIMD3<Float>, n: Float)]()
            eachEdge(near: eye, within: 4.5) { e, p, q in
                guard seen[e] == 1 else { return }
                let mid = (p + q) / 2, far = simd_length(mid - eye)
                guard far > 0.7, far < 3.5 else { return }   // farther out the pieces around are not all counted
                var b = blocks[Self.key(mid, cell: 0.5)] ?? (0, SIMD3<Float>(repeating: 0), 0)
                b.length += simd_length(p - q)
                b.sum += mid
                b.n += 1
                blocks[Self.key(mid, cell: 0.5)] = b
            }
            let best = blocks.values.max { $0.length < $1.length }
            let found = best.flatMap { $0.length >= 1.5 ? $0.sum / $0.n : nil }
            Task { @MainActor in then(found) }
        }
    }

    /// The cells as points seen from `eye`: those facing away are left out, so a room is
    /// looked into through its ceiling and its near walls.
    func model(from eye: SIMD3<Float>, oldOnly: Bool = false, then: @escaping @MainActor (Model) -> Void) {
        queue.async { [self] in
            var p = [SIMD3<Float>](), c = [SIMD3<Float>]()
            p.reserveCapacity(pos.count / 2)
            c.reserveCapacity(pos.count / 2)
            var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
            for i in pos.indices where hits[i] >= 2 && (!oldOnly || old[i]) {
                lo = simd_min(lo, pos[i])
                hi = simd_max(hi, pos[i])
                if simd_dot(dir[i], eye - pos[i]) > 0 {
                    p.append(pos[i])
                    c.append(col[i])
                }
            }
            let shot = Model(positions: Self.data(p), colours: Self.data(c), count: p.count, lo: lo, hi: hi)
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

    /// Reads a depth file back (DepthLog's format), a frame at a time, thinned like live frames.
    static func read(_ url: URL, each: (Sample) -> Void) {
        guard let fh = try? FileHandle(forReadingFrom: url), (try? fh.read(upToCount: 4)) == Data("RPD1".utf8) else { return }
        defer { try? fh.close() }
        while let lead = try? fh.read(upToCount: 4), lead.count == 4 {
            let n = Int(lead.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            guard let hj = try? fh.read(upToCount: n), hj.count == n,
                  let h = try? JSONSerialization.jsonObject(with: hj) as? [String: Any],
                  let w = h["w"] as? Int, let hh = h["h"] as? Int, let iw = h["iw"] as? Int, let ih = h["ih"] as? Int,
                  let K = (h["K"] as? [NSNumber])?.map(\.floatValue), K.count == 9,
                  let T = (h["T"] as? [NSNumber])?.map(\.floatValue), T.count == 16,
                  let dz = h["dz"] as? Int, let cz = h["cz"] as? Int, let jz = h["jz"] as? Int,
                  let draw = try? fh.read(upToCount: dz), draw.count == dz,
                  let craw = try? fh.read(upToCount: cz), craw.count == cz,
                  let jpeg = try? fh.read(upToCount: jz), jpeg.count == jz else { return }
            guard let depth = try? (draw as NSData).decompressed(using: .zlib) as Data, depth.count == w * hh * 2,
                  let trust = try? (craw as NSData).decompressed(using: .zlib) as Data, trust.count == w * hh,
                  let image = UIImage(data: jpeg)?.cgImage else { continue }
            let jw = image.width, jh = image.height
            var pixels = [UInt8](repeating: 0, count: jw * jh * 4)
            guard let ctx = CGContext(data: &pixels, width: jw, height: jh, bitsPerComponent: 8, bytesPerRow: jw * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: jw, height: jh))
            let sx = Float(w) / Float(iw), sy = Float(hh) / Float(ih)
            let fx = K[0] * sx, fy = K[4] * sy, cx = K[2] * sx, cy = K[5] * sy
            var points = [SIMD3<Float>](), colours = [SIMD3<Float>]()
            depth.withUnsafeBytes { (d: UnsafeRawBufferPointer) in
                for y in stride(from: 1, to: hh, by: 2) {
                    for x in stride(from: 1, to: w, by: 2) {
                        let z = Float(d.loadUnaligned(fromByteOffset: (y * w + x) * 2, as: Float16.self))
                        guard z.isFinite, z > 0.15, z < 5 else { continue }
                        let c = trust[trust.startIndex + y * w + x]
                        if c == 0 || (c == 1 && z > 3) { continue }
                        let o = (min(jh - 1, y * jh / hh) * jw + min(jw - 1, x * jw / w)) * 4
                        let rgb = SIMD3<Float>(Float(pixels[o]), Float(pixels[o + 1]), Float(pixels[o + 2])) / 255
                        colours.append(rgb * rgb)
                        points.append(SIMD3<Float>((Float(x) - cx) / fx * z, -(Float(y) - cy) / fy * z, -z))
                    }
                }
            }
            let m = simd_float4x4(SIMD4<Float>(T[0], T[1], T[2], T[3]), SIMD4<Float>(T[4], T[5], T[6], T[7]),
                                  SIMD4<Float>(T[8], T[9], T[10], T[11]), SIMD4<Float>(T[12], T[13], T[14], T[15]))
            each(Sample(points: points, colours: colours, T: m, centre: nil))
        }
    }
}
