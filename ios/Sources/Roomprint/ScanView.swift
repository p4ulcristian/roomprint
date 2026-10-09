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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .bottom) {
            CaptureViewRep(view: ctl.captureView).ignoresSafeArea()
            VStack(spacing: 12) {
                if let uploadStep {
                    ProgressView { Text(uploadStep) }
                } else if let error {
                    Text(error).foregroundStyle(.red)
                    Button("Close") { dismiss() }
                } else {
                    controls
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
        .overlay(alignment: .topLeading) {
            if uploadStep == nil {
                Button { ctl.stopAll(); dismiss() } label: {
                    Image(systemName: "xmark").padding(12).background(.ultraThinMaterial, in: Circle())
                }
                .padding()
            }
        }
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
            Text(ctl.rooms.isEmpty ? "Walk slowly along the walls. Point at doors and windows. Say the room's name."
                 : "Room \(ctl.rooms.count + 1): go on into the next room.")
                .font(.callout).multilineTextAlignment(.center)
            Button("Done with this room") { ctl.finishRoom() }
                .buttonStyle(.borderedProminent)
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
                .buttonStyle(.bordered)
                Button("Finish & upload") {
                    ctl.nameLastRoom(roomName)
                    Task { await upload() }
                }
                .buttonStyle(.borderedProminent)
            }
            Text("\(ctl.rooms.count) room\(ctl.rooms.count == 1 ? "" : "s") scanned").font(.caption)
        case .failed(let msg):
            Text("The scan failed: \(msg)").foregroundStyle(.red)
            Button("Try this room again") { ctl.startRoom() }
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
            uploadStep = "Joining the rooms…"
            let structure = try await ctl.build()
            let stamp = Int(Date().timeIntervalSince1970)
            let dir = FileManager.default.temporaryDirectory
            let jsonURL = dir.appendingPathComponent("scan-\(stamp).roomplan")
            try ScanExport.json(structure, names: ctl.names).write(to: jsonURL)
            let usdzURL = dir.appendingPathComponent("scan-\(stamp).usdz")
            let haveUSDZ = (try? structure.export(to: usdzURL)) != nil

            uploadStep = "Queueing the uploads…"
            let files = [jsonURL] + (haveUSDZ ? [usdzURL] : []) + [video, depth].compactMap { $0 }
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
