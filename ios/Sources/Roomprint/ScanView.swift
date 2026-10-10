import RoomPlan
import SwiftUI

/// Drives Apple's RoomCaptureView through one or more rooms. Between rooms the AR
/// session keeps running, so every room is scanned in the same coordinate frame and
/// StructureBuilder can join them into one floor plan.
@MainActor
final class ScanController: NSObject, ObservableObject, @preconcurrency RoomCaptureViewDelegate {
    enum Phase { case scanning, processing, reviewing, failed(String) }

    let captureView = RoomCaptureView(frame: .zero)
    /// Films the whole scan (camera + microphone), across every room.
    private(set) lazy var recorder = WalkRecorder(session: captureView.captureSession.arSession)
    @Published var phase: Phase = .scanning
    @Published private(set) var rooms: [CapturedRoom] = []
    private(set) var names: [String?] = []

    override init() {
        super.init()
        captureView.delegate = self
    }

    // RoomCaptureViewDelegate inherits NSCoding; this controller is never archived.
    required init?(coder: NSCoder) { return nil }
    func encode(with coder: NSCoder) {}

    func startRoom() {
        phase = .scanning
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        recorder.start()  // no-op after the first room: one video for the whole walk
    }

    func finishRoom() {
        phase = .processing
        captureView.captureSession.stop(pauseARSession: false)
    }

    /// Name for the room just reviewed; call before startRoom() or build().
    func nameLastRoom(_ name: String) {
        while names.count < rooms.count - 1 { names.append(nil) }
        if names.count < rooms.count { names.append(name.trimmingCharacters(in: .whitespaces)) }
    }

    func stopAll() {
        captureView.captureSession.stop()
        Task { _ = await recorder.finish() }
    }

    /// The video of the walk, with sound; call before build() stops the AR session.
    func finishVideo() async -> URL? {
        await recorder.finish()
    }

    /// The LiDAR depth of the walk, for the real 3D model (nil if the phone gave none).
    func finishDepth() async -> URL? {
        await recorder.finishDepth()
    }

    /// The camera pose of every video frame, for the model's photo texture.
    func finishPoses() async -> URL? {
        await recorder.finishPoses()
    }

    func build() async throws -> CapturedStructure {
        captureView.captureSession.stop()
        let builder = StructureBuilder(options: [.beautifyObjects])
        return try await builder.capturedStructure(from: rooms)
    }

    nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    nonisolated func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        Task { @MainActor in
            if let error {
                self.phase = .failed(error.localizedDescription)
            } else {
                self.rooms.append(processedResult)
                self.phase = .reviewing
            }
        }
    }
}

struct CaptureViewRep: UIViewRepresentable {
    let view: RoomCaptureView
    func makeUIView(context: Context) -> RoomCaptureView { view }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

struct ScanView: View {
    let space: SavedSpace
    var onDone: () -> Void

    @StateObject private var ctl = ScanController()
    @State private var roomName = ""
    @State private var uploadStep: String?
    @State private var error: String?
    @State private var looking = false
    @AppStorage("scanDots") private var dots = true
    @Environment(\.dismiss) private var dismiss

    private var scanning: Bool {
        if case .scanning = ctl.phase { return uploadStep == nil && error == nil }
        return false
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CaptureViewRep(view: ctl.captureView).ignoresSafeArea()
            if dots, scanning { CoverageDots(live: ctl.recorder.live) }
            VStack(spacing: 12) {
                if scanning { HintPill(live: ctl.recorder.live) }
                VStack(spacing: 12) {
                    if let uploadStep {
                        ProgressView { Text(uploadStep) }
                    } else if let error {
                        Text(error).foregroundStyle(.red)
                        Button("Close") { dismiss() }.glassButton()
                    } else {
                        controls
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity)
                .glass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
            .padding()
        }
        .overlay(alignment: .topLeading) {
            if uploadStep == nil {
                CloseButton { ctl.stopAll(); dismiss() }.padding()
            }
        }
        .overlay(alignment: .topTrailing) {
            if uploadStep == nil, error == nil {
                ScanCorner(live: ctl.recorder.live, dots: $dots) { looking = true }.padding()
            }
        }
        .fullScreenCover(isPresented: $looking) {
            ModelLook(live: ctl.recorder.live) {
                Button("Back to the scan") { looking = false }.glassButton(prominent: true)
            }
        }
        .onChange(of: looking) { _, on in ctl.recorder.paused = on }
        .onAppear { ctl.startRoom() }
        .onDisappear { ctl.stopAll() }
    }

    @ViewBuilder private var controls: some View {
        switch ctl.phase {
        case .scanning:
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let n = ctl.recorder.depth.count
                Label(n > 0 ? "Filming with sound · depth \(n)" : "Filming with sound · no depth yet",
                      systemImage: "record.circle").font(.caption).foregroundStyle(.red)
            }
            Text(ctl.rooms.isEmpty ? "Walk slowly along the walls. Point at doors and windows. The small model shows what is scanned; dark gaps are not."
                 : "Room \(ctl.rooms.count + 1): go on into the next room.")
                .font(.callout).multilineTextAlignment(.center)
            Button("Done with this room") { ctl.finishRoom() }
                .glassButton(prominent: true)
        case .processing:
            ProgressView("Processing the room…")
        case .reviewing:
            TextField("Room name (optional)", text: $roomName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Scan next room") {
                    ctl.nameLastRoom(roomName); roomName = ""
                    ctl.startRoom()
                }
                .glassButton()
                Button("Finish & upload") {
                    ctl.nameLastRoom(roomName)
                    Task { await upload() }
                }
                .glassButton(prominent: true)
            }
            Text("\(ctl.rooms.count) room\(ctl.rooms.count == 1 ? "" : "s") scanned").font(.caption)
        case .failed(let msg):
            Text("The scan failed: \(msg)").foregroundStyle(.red)
            Button("Try this room again") { ctl.startRoom() }.glassButton()
        }
    }

    private func upload() async {
        // Only the saving happens here; the uploads themselves go to iOS (Uploader), which
        // finishes them even if the app is closed. The server starts on the scan by itself.
        let bg = UIApplication.shared.beginBackgroundTask(withName: "save")
        defer { UIApplication.shared.endBackgroundTask(bg) }
        do {
            uploadStep = "Saving the video…"
            let video = await ctl.finishVideo()
            let depth = await ctl.finishDepth()
            let poses = await ctl.finishPoses()
            uploadStep = "Joining the rooms…"
            let structure = try await ctl.build()
            let stamp = Int(Date().timeIntervalSince1970)
            let dir = FileManager.default.temporaryDirectory
            let jsonURL = dir.appendingPathComponent("scan-\(stamp).roomplan")
            try ScanExport.json(structure, names: ctl.names).write(to: jsonURL)
            let usdzURL = dir.appendingPathComponent("scan-\(stamp).usdz")
            let haveUSDZ = (try? structure.export(to: usdzURL)) != nil

            uploadStep = "Queueing the uploads…"
            // The scan first (the floor plan is made from it alone), the video last: it is the biggest.
            let files = [jsonURL] + (haveUSDZ ? [usdzURL] : []) + [poses, depth, video].compactMap { $0 }
            let space = space
            try await Task.detached {   // copying a long video into chunks takes a moment
                for f in files { try Uploader.shared.enqueue(space, file: f, filename: f.lastPathComponent) }
            }.value
            await Uploader.shared.resume()
            uploadStep = nil
            onDone()
            dismiss()
        } catch {
            uploadStep = nil
            self.error = error.localizedDescription
        }
    }
}
