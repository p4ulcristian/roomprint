import SceneKit
import SwiftUI

/// A SceneKit view of one of LiveScan's scenes.
struct SceneRep: UIViewRepresentable {
    let scene: SCNScene
    let camera: SCNNode
    /// See-through and untouchable: for drawing over the camera image.
    var clear = false
    var made: (SCNView) -> Void = { _ in }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        v.scene = scene
        v.pointOfView = camera
        v.antialiasingMode = .none
        v.preferredFramesPerSecond = 30
        v.rendersContinuously = true
        v.isPlaying = true
        if clear {
            v.backgroundColor = .clear
            v.isOpaque = false
            v.isUserInteractionEnabled = false
        }
        made(v)
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {}
}

/// Dots over the camera image on every surface scanned so far; orange where it was seen too little.
struct CoverageDots: View {
    let live: LiveScan

    var body: some View {
        SceneRep(scene: live.overlay, camera: live.overlayCamera, clear: true) { live.overlayView = $0 }
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// The corner of a scanning screen: the scan so far in small (tap for a proper look), and
/// the switch for the dots.
struct ScanCorner: View {
    let live: LiveScan
    @Binding var dots: Bool
    var open: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            Button(action: open) {
                SceneRep(scene: live.model, camera: live.insetCamera)
                    .allowsHitTesting(false)
                    .frame(width: 116, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white).padding(8)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Look at the scan so far")
            Button { dots.toggle() } label: {
                Image(systemName: dots ? "circle.grid.3x3.fill" : "circle.grid.3x3")
                    .font(.body.weight(.semibold)).frame(width: 44, height: 44)
            }
            .foregroundStyle(.primary)
            .glass(in: Circle())
            .accessibilityLabel(dots ? "Hide the dots on scanned surfaces" : "Show dots on scanned surfaces")
        }
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
                Text("Dark gaps have not been scanned. Drag to turn it, pinch to zoom.")
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
