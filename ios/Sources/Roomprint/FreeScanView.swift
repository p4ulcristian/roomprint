import ARKit
import SceneKit
import SwiftUI

/// A scan without rooms: anything the LiDAR can see (an object, one wall, a stairwell, a
/// garden corner). The walk is filmed and its depth and camera poses recorded exactly like
/// a room scan's; the server builds the 3D model from those. What has been covered so far
/// shows while scanning (LiveScan): its tint is drawn in this camera view, on the surfaces.
@MainActor
final class FreeScanController: ObservableObject {
    let view = ARSCNView(frame: .zero)
    private(set) lazy var recorder = WalkRecorder(session: view.session)

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
        config.sceneReconstruction = .mesh
        config.environmentTexturing = .none
        view.scene = recorder.live.tint
        view.automaticallyUpdatesLighting = false
        view.antialiasingMode = .none
        view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        recorder.start()
    }

    func stop() {
        Task { _ = await recorder.finish() }
        view.session.pause()
    }
}

struct ARViewRep: UIViewRepresentable {
    let view: ARSCNView
    func makeUIView(context: Context) -> ARSCNView { view }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct FreeScanView: View {
    let space: SavedSpace
    var onDone: () -> Void

    @StateObject private var ctl = FreeScanController()
    @State private var step: String?
    @State private var error: String?
    @State private var looking = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .bottom) {
            ARViewRep(view: ctl.view).ignoresSafeArea()
            VStack(spacing: 12) {
              HintPill(live: ctl.recorder.live)
              VStack(spacing: 12) {
                if let step {
                    ProgressView { Text(step) }
                } else if let error {
                    Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                    Button("Close") { dismiss() }.glassButton()
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let n = ctl.recorder.depth.count
                        Label(n > 0 ? "Filming with sound · depth \(n)" : "Filming with sound · no depth yet",
                              systemImage: "record.circle").font(.caption).foregroundStyle(.red)
                    }
                    Text("Move slowly around what you want to scan, about a metre away. Scanned surfaces get a light tint; orange needs another look.")
                        .font(.callout).multilineTextAlignment(.center)
                    Button("Finish") { looking = true }
                        .glassButton(prominent: true)
                }
              }
              .padding(18)
              .frame(maxWidth: .infinity)
              .glass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
            .padding()
        }
        .overlay(alignment: .topLeading) {
            if step == nil {
                CloseButton { ctl.stop(); dismiss() }.padding()
            }
        }
        .overlay(alignment: .topTrailing) {
            if step == nil, error == nil {
                ScanMap(live: ctl.recorder.live) { looking = true }.padding()
            }
        }
        // Before anything is uploaded: the scan to turn around, and the choice to go on.
        .fullScreenCover(isPresented: $looking) {
            ModelLook(live: ctl.recorder.live) {
                Button("Scan more") { looking = false }.glassButton()
                Button("Upload") {
                    looking = false
                    Task { await upload() }
                }
                .glassButton(prominent: true)
            }
        }
        .onChange(of: looking) { _, on in ctl.recorder.paused = on }
        .onAppear { ctl.start() }
        .onDisappear { ctl.stop() }
    }

    private func upload() async {
        let bg = UIApplication.shared.beginBackgroundTask(withName: "save")
        defer { UIApplication.shared.endBackgroundTask(bg) }
        step = "Saving the video…"
        let seconds = ctl.recorder.started.map { Date().timeIntervalSince($0) } ?? 0
        let video = await ctl.recorder.finish()
        let depth = await ctl.recorder.finishDepth()
        let poses = await ctl.recorder.finishPoses()
        ctl.view.session.pause()
        guard let depth else {
            step = nil
            error = "No depth was recorded, so there is nothing to build a model from. Try again and move a little slower."
            return
        }
        do {
            // The scan's own small file: the server starts on a free scan when it arrives.
            let note = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(Int(Date().timeIntervalSince1970)).freescan")
            try JSONSerialization.data(withJSONObject: ["version": 1, "seconds": Int(seconds), "depth_frames": ctl.recorder.depth.count])
                .write(to: note)
            step = "Queueing the uploads…"
            let files = [note] + [poses, depth, video].compactMap { $0 }
            let space = space
            try await Task.detached {
                for f in files { try Uploader.shared.enqueue(space, file: f, filename: f.lastPathComponent) }
            }.value
            await Uploader.shared.resume()
            step = nil
            onDone()
            dismiss()
        } catch {
            step = nil
            self.error = error.localizedDescription
        }
    }
}
