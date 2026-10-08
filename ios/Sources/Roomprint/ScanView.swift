import RoomPlan
import SwiftUI

/// Drives Apple's RoomCaptureView through one or more rooms. Between rooms the AR
/// session keeps running, so every room is scanned in the same coordinate frame and
/// StructureBuilder can join them into one floor plan.
@MainActor
final class ScanController: NSObject, ObservableObject, @preconcurrency RoomCaptureViewDelegate {
    enum Phase { case scanning, processing, reviewing, failed(String) }

    let captureView = RoomCaptureView(frame: .zero)
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
    @State private var uploadProgress = 0.0
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .bottom) {
            CaptureViewRep(view: ctl.captureView).ignoresSafeArea()
            VStack(spacing: 12) {
                if let uploadStep {
                    ProgressView(value: uploadProgress) { Text(uploadStep) }
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
            Text(ctl.rooms.isEmpty ? "Walk slowly along the walls. Point at doors and windows."
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
        do {
            uploadStep = "Joining the rooms…"
            let structure = try await ctl.build()
            let stamp = Int(Date().timeIntervalSince1970)
            let dir = FileManager.default.temporaryDirectory
            let jsonURL = dir.appendingPathComponent("scan-\(stamp).roomplan")
            try ScanExport.json(structure, names: ctl.names).write(to: jsonURL)
            let usdzURL = dir.appendingPathComponent("scan-\(stamp).usdz")
            let haveUSDZ = (try? structure.export(to: usdzURL)) != nil

            if haveUSDZ {
                uploadStep = "Uploading the 3D model…"
                try await API.upload(space, file: usdzURL, filename: usdzURL.lastPathComponent) { p in
                    Task { @MainActor in uploadProgress = p }
                }
            }
            uploadStep = "Uploading the floor plan…"
            try await API.upload(space, file: jsonURL, filename: jsonURL.lastPathComponent) { p in
                Task { @MainActor in uploadProgress = p }
            }
            uploadStep = "Starting…"
            try await API.submit(space)
            uploadStep = nil
            onDone()
            dismiss()
        } catch {
            uploadStep = nil
            self.error = error.localizedDescription
        }
    }
}
