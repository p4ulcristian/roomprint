import ARKit
import AVFoundation
import RoomPlan
import SceneKit
import SwiftUI

/// One scan, from the first frame to "Done": the camera view, the recording (WalkRecorder),
/// the picture of the scan so far (LiveScan) and, when a floor plan is wanted, RoomPlan
/// running beside them on the same AR session. Everything is written into the scan's
/// folder on the phone (ScanStore); uploading is a separate step.
///
/// A kept scan can be continued: ARKit finds the place again from its saved map, so the
/// new part lands in the same coordinates as the old.
@MainActor
final class CaptureController: NSObject, ObservableObject, RoomCaptureSessionDelegate {
    enum Phase: Equatable { case finding, scanning, saving(String), failed(String) }

    let view = ARSCNView(frame: .zero)
    let recorder: WalkRecorder
    @Published private(set) var scan: KeptScan
    @Published private(set) var phase: Phase = .scanning
    @Published private(set) var torch = false
    /// True while RoomPlan is working a finished room out; the next cannot be closed meanwhile.
    @Published private(set) var closingRoom = false
    /// False for a scan continued from an earlier day.
    let fresh: Bool

    private var rooms: RoomCaptureSession?
    private var ending: CheckedContinuation<Void, Never>?
    private var walls: [(transform: simd_float4x4, size: SIMD3<Float>, opening: Bool)] = []   // of the rooms already finished
    private var lastPlan = Date.distantPast
    private var watch: Timer?
    private var stopped = false

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }
    static var canPlan: Bool { RoomCaptureSession.isSupported }

    init(scan: KeptScan) {
        self.scan = scan
        fresh = scan.segments == 0
        recorder = WalkRecorder(session: view.session, dir: ScanStore.dir(scan), segment: scan.segments, offset: scan.seconds)
        super.init()
    }

    // RoomCaptureSessionDelegate inherits NSCoding; this controller is never archived.
    required init?(coder: NSCoder) { return nil }
    func encode(with coder: NSCoder) {}

    func start() {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) { config.sceneReconstruction = .mesh }
        config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        config.environmentTexturing = .none
        if !fresh {
            guard let data = try? Data(contentsOf: ScanStore.worldMap(ScanStore.dir(scan))),
                  let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
                // Without the map the new part would land somewhere else than the old.
                stopped = true
                phase = .failed("This scan has no map of its place, so it cannot be continued. It can still be uploaded as it is.")
                return
            }
            config.initialWorldMap = map
        }
        view.scene = recorder.live.tint
        view.automaticallyUpdatesLighting = false
        view.antialiasingMode = .none
        view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        if config.initialWorldMap == nil {
            begin()
        } else {
            // Nothing is recorded until ARKit knows where it is in the old scan.
            phase = .finding
            watch = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.found() }
            }
        }
    }

    private func found() {
        guard phase == .finding, let cam = view.session.currentFrame?.camera, case .normal = cam.trackingState else { return }
        watch?.invalidate()
        phase = .scanning
        recorder.live.replay(ScanStore.depth(ScanStore.dir(scan)))
        walls = ScanStore.rooms(scan).flatMap(Self.surfaces)
        recorder.live.plan(walls)
        begin()
    }

    private func begin() {
        if scan.plan, Self.canPlan {
            let r = RoomCaptureSession(arSession: view.session)
            r.delegate = self
            r.run(configuration: RoomCaptureSession.Configuration())
            rooms = r
            // RoomPlan sets the session up its own way; if that left ARKit's mesh out, ask for it again.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                self?.wantMesh()
            }
        }
        recorder.start()
    }

    private func wantMesh() {
        guard !stopped, ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh),
              let frame = view.session.currentFrame, !frame.anchors.contains(where: { $0 is ARMeshAnchor }),
              let config = view.session.configuration as? ARWorldTrackingConfiguration, !config.sceneReconstruction.contains(.mesh) else { return }
        config.sceneReconstruction.insert(.mesh)
        view.session.run(config)
    }

    /// For the screen: the scan is safe on the phone, but something after that went wrong.
    func fail(_ message: String) { phase = .failed(message) }

    func setTorch(_ on: Bool) {
        guard let d = AVCaptureDevice.default(for: .video), d.hasTorch, (try? d.lockForConfiguration()) != nil else { return }
        d.torchMode = on ? .on : .off
        d.unlockForConfiguration()
        torch = on
    }

    // MARK: rooms

    /// Closes the room being scanned (RoomPlan works a room at a time) and starts the next.
    func nextRoom(name: String) async {
        await endRoom(name: name)
        rooms?.run(configuration: RoomCaptureSession.Configuration())
    }

    private func endRoom(name: String) async {
        guard let rooms else { return }
        guard !closingRoom else { return }
        closingRoom = true
        defer { closingRoom = false }
        let before = scan.rooms
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            ending = k
            rooms.stop(pauseARSession: false)
            // RoomPlan normally answers within seconds; the scan must not hang on it.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.ending?.resume()
                self?.ending = nil
            }
        }
        if scan.rooms > before {
            while scan.names.count < before { scan.names.append(nil) }
            scan.names.append(name.trimmingCharacters(in: .whitespaces))
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let now = Self.surfaces(room)
        Task { @MainActor in
            guard Date().timeIntervalSince(self.lastPlan) > 0.7 else { return }
            self.lastPlan = Date()
            self.recorder.live.plan(self.walls + now)
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        Task { @MainActor in
            // A room RoomPlan could make nothing of (an object, a corner) is simply not a room.
            if error == nil, let room = try? await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data),
               !room.walls.isEmpty, let json = try? JSONEncoder().encode(room) {
                try? json.write(to: ScanStore.room(ScanStore.dir(self.scan), self.scan.rooms))
                self.scan.rooms += 1
                self.walls += Self.surfaces(room)
                self.recorder.live.plan(self.walls)
            }
            self.ending?.resume()
            self.ending = nil
        }
    }

    nonisolated private static func surfaces(_ room: CapturedRoom) -> [(transform: simd_float4x4, size: SIMD3<Float>, opening: Bool)] {
        room.walls.map { ($0.transform, $0.dimensions, false) }
            + (room.doors + room.windows + room.openings).map { ($0.transform, $0.dimensions, true) }
    }

    // MARK: the end

    /// Stops and keeps the scan on the phone; returns it as kept, or nil with `phase` failed.
    func finish(roomName: String) async -> KeptScan? {
        guard !stopped else { return scan }
        stopped = true
        watch?.invalidate()
        setTorch(false)
        phase = .saving("Saving the scan…")
        recorder.paused = true
        let bg = UIApplication.shared.beginBackgroundTask(withName: "save")
        defer { UIApplication.shared.endBackgroundTask(bg) }
        if rooms != nil { await endRoom(name: roomName) }
        // ARKit's map of the place, so the scan can be continued another day.
        if let map = try? await view.session.currentWorldMap(),
           let data = try? NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true) {
            try? data.write(to: ScanStore.worldMap(ScanStore.dir(scan)), options: .atomic)
        }
        let video = await recorder.finish()
        let depth = await recorder.finishDepth()
        _ = await recorder.finishPoses()
        view.session.pause()
        guard depth != nil else {
            ScanStore.delete(scan)
            phase = .failed("No depth was recorded, so there is nothing to build a model from. Try again and move a little slower.")
            return nil
        }
        if let video { scan.seconds += await ScanStore.length(video) }
        scan.segments += 1
        scan.area = recorder.live.area
        scan.updated = Date()
        ScanStore.save(scan)
        return scan
    }

    /// Stops without keeping what this session added. A fresh scan is gone; one that was
    /// being continued cannot be cut back (its depth and poses are already in its files),
    /// so that one is kept as it now is.
    func discard() async {
        if fresh {
            stopped = true
            watch?.invalidate()
            setTorch(false)
            _ = await recorder.finish()
            view.session.pause()
            ScanStore.delete(scan)
        } else if phase == .finding {
            stopped = true
            watch?.invalidate()
            view.session.pause()
        } else {
            _ = await finish(roomName: "")
        }
    }
}

private extension ARSession {
    func currentWorldMap() async throws -> ARWorldMap {
        try await withCheckedThrowingContinuation { k in
            getCurrentWorldMap { map, error in
                if let map { k.resume(returning: map) } else { k.resume(throwing: error ?? APIError(message: "no map")) }
            }
        }
    }
}

struct ARViewRep: UIViewRepresentable {
    let view: ARSCNView
    func makeUIView(context: Context) -> ARSCNView { view }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

/// The scanning screen.
struct CaptureView: View {
    let space: SavedSpace
    var onDone: () -> Void

    @StateObject private var ctl: CaptureController
    @State private var looking = false
    @State private var guide = false
    @State private var naming = false
    @State private var roomName = ""
    @State private var askClose = false
    @State private var follow = true
    @AppStorage("guideSeen") private var guideSeen = false
    @Environment(\.dismiss) private var dismiss

    init(space: SavedSpace, scan: KeptScan, onDone: @escaping () -> Void) {
        self.space = space
        self.onDone = onDone
        _ctl = StateObject(wrappedValue: CaptureController(scan: scan))
    }

    private var live: LiveScan { ctl.recorder.live }
    private var planning: Bool { ctl.scan.plan && CaptureController.canPlan }

    var body: some View {
        ZStack(alignment: .bottom) {
            ARViewRep(view: ctl.view).ignoresSafeArea()
            if ctl.phase == .scanning { GapArrow(live: live) }
            VStack(spacing: 12) {
                if ctl.phase == .scanning { HintPill(live: live) }
                VStack(spacing: 12) { card }
                    .padding(18)
                    .frame(maxWidth: .infinity)
                    .glass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
            .padding()
        }
        .overlay(alignment: .topLeading) {
            if ctl.phase == .scanning || ctl.phase == .finding {
                CloseButton {
                    if ctl.phase == .finding { close() } else { askClose = true }
                }
                .padding()
            }
        }
        .overlay(alignment: .topTrailing) {
            if ctl.phase == .scanning { corner.padding() }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            ctl.start()
            if !guideSeen { guide = true }
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: looking || guide || naming) { _, on in
            if ctl.phase == .scanning { ctl.recorder.paused = on }
        }
        .sheet(isPresented: $guide, onDismiss: { guideSeen = true }) { GuideCards { guide = false } }
        .fullScreenCover(isPresented: $looking) { review }
        .alert("Name this room", isPresented: $naming) {
            TextField("Kitchen, bedroom… (optional)", text: $roomName)
            Button("Next room") {
                let name = roomName
                roomName = ""
                Task { await ctl.nextRoom(name: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This room is closed for the floor plan and the next one starts. Keep the phone up and walk on.")
        }
        .confirmationDialog(ctl.fresh ? "Throw this scan away?" : "Stop here?", isPresented: $askClose, titleVisibility: .visible) {
            if ctl.fresh {
                Button("Throw it away", role: .destructive) { close() }
            } else {
                Button("Stop and keep it") { close() }
            }
            Button("Go on scanning", role: .cancel) {}
        } message: {
            Text(ctl.fresh ? "Nothing of it is kept or uploaded." : "What was added just now stays in the scan on this phone.")
        }
    }

    @ViewBuilder private var card: some View {
        switch ctl.phase {
        case .finding:
            ProgressView()
            Text("Finding the place again").font(.headline)
            Text("Point the phone at something you scanned last time, from about where you stood then.")
                .font(.callout).multilineTextAlignment(.center)
        case .scanning:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let s = Int(ctl.scan.seconds + (ctl.recorder.started.map { Date().timeIntervalSince($0) } ?? 0))
                HStack(spacing: 10) {
                    Label(String(format: "%d:%02d", s / 60, s % 60), systemImage: "record.circle").foregroundStyle(.red)
                    AreaLabel(live: live)
                    if planning { Text("Room \(ctl.scan.rooms + 1)") }
                }
                .font(.caption.weight(.medium)).monospacedDigit()
            }
            Text("Move slowly, about a metre from things. Scanned surfaces get a light tint; orange needs another look.")
                .font(.callout).multilineTextAlignment(.center)
            HStack {
                if planning { Button("Next room") { naming = true }.glassButton().disabled(ctl.closingRoom) }
                Button("Done") { looking = true }.glassButton(prominent: true).disabled(ctl.closingRoom)
            }
        case .saving(let step):
            ProgressView { Text(step) }
        case .failed(let message):
            Text(message).foregroundStyle(.red).multilineTextAlignment(.center)
            Button("Close") { dismiss() }.glassButton()
        }
    }

    /// The map, and under it the small switches: map follows or shows all, light, help.
    private var corner: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ScanMap(live: live) { looking = true }
            HStack(spacing: 8) {
                round(follow ? "location.north.line.fill" : "map", follow ? "Show the whole scan on the map" : "Keep the map on where I am") {
                    follow.toggle()
                    live.follow = follow
                }
                round(ctl.torch ? "flashlight.on.fill" : "flashlight.off.fill", "Light") { ctl.setTorch(!ctl.torch) }
                round("questionmark", "How to scan") { guide = true }
            }
        }
    }

    private func round(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.callout.weight(.semibold)).frame(width: 40, height: 40)
        }
        .foregroundStyle(.primary)
        .glass(in: Circle())
        .accessibilityLabel(label)
    }

    /// "Done": the scan to turn around, then what to do with it.
    private var review: some View {
        ModelLook(live: live) {
            VStack(spacing: 10) {
                if planning {
                    TextField("Name of this last room (optional)", text: $roomName).textFieldStyle(.roundedBorder)
                }
                Button { end(upload: true) } label: { Text("Upload").frame(maxWidth: .infinity) }.glassButton(prominent: true)
                HStack {
                    Button { looking = false } label: { Text("Scan more").frame(maxWidth: .infinity) }.glassButton()
                    Button { end(upload: false) } label: { Text("Keep on phone").frame(maxWidth: .infinity) }.glassButton()
                }
                Text("Either way it stays on this phone, to continue or upload again later.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private func end(upload: Bool) {
        looking = false
        Task {
            guard let kept = await ctl.finish(roomName: roomName) else { return }
            if upload {
                do {
                    try await ScanStore.upload(kept, to: space)
                } catch {
                    // The scan is safe on the phone; it can be uploaded from the space's page.
                    ctl.fail("The scan is kept on this phone, but could not be queued for upload: \(error.localizedDescription) Try again from the space's page.")
                    onDone()
                    return
                }
            }
            onDone()
            dismiss()
        }
    }

    private func close() {
        Task {
            await ctl.discard()
            onDone()
            dismiss()
        }
    }
}

private struct AreaLabel: View {
    @ObservedObject var live: LiveScan
    var body: some View {
        Text("\(Int(live.area)) m² of surface")
    }
}
