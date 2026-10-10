import SceneKit
import SwiftUI

/// A SceneKit view of one of LiveScan's scenes.
struct SceneRep: UIViewRepresentable {
    let scene: SCNScene
    let camera: SCNNode
    var made: (SCNView) -> Void = { _ in }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        v.scene = scene
        v.pointOfView = camera
        v.antialiasingMode = .none
        v.preferredFramesPerSecond = 30
        v.rendersContinuously = true
        v.isPlaying = true
        made(v)
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {}
}

/// The corner of a scanning screen: the scan so far from above, with the phone's place
/// on it. Tap for a proper look.
struct ScanMap: View {
    let live: LiveScan
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            SceneRep(scene: live.model, camera: live.mapCamera)
                .allowsHitTesting(false)
                .frame(width: 136, height: 136)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white).padding(9)
                }
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Look at the scan so far")
    }
}

/// One line of advice while scanning, when there is any.
struct HintPill: View {
    @ObservedObject var live: LiveScan

    var body: some View {
        if let hint = live.hint {
            Label(hint, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glass(in: Capsule())
                .transition(.opacity)
        }
    }
}

/// The scan so far, full screen, to turn around and check for gaps. The scan is paused
/// while this is up; `buttons` say what happens next.
struct ModelLook<Buttons: View>: View {
    let live: LiveScan
    @ViewBuilder var buttons: Buttons

    var body: some View {
        ZStack(alignment: .bottom) {
            SceneRep(scene: live.model, camera: live.fullCamera) { v in
                live.openFull()
                v.allowsCameraControl = true
                v.defaultCameraController.interactionMode = .orbitTurntable
                v.defaultCameraController.target = live.lookAt
                live.fullView = v
            }
            .ignoresSafeArea()
            VStack(spacing: 12) {
                Text("The scan so far").font(.headline)
                Text("Dark gaps have not been scanned; orange lines mark their edges. Drag to turn it, pinch to zoom.")
                    .font(.callout).multilineTextAlignment(.center)
                HStack { buttons }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .glass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding()
        }
        .preferredColorScheme(.dark)
    }
}
