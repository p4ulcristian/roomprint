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
                buttons
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .glass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding()
        }
        .preferredColorScheme(.dark)
    }
}

/// An arrow at the rim of the screen towards a gap that is out of sight.
struct GapArrow: View {
    @ObservedObject var live: LiveScan

    var body: some View {
        GeometryReader { g in
            if let a = live.arrow {
                let r = min(g.size.width, g.size.height) * 0.36
                VStack(spacing: 2) {
                    Image(systemName: "arrowtriangle.up.fill").font(.title3)
                    Text("gap").font(.caption2.weight(.bold)).rotationEffect(.radians(-a))
                }
                .foregroundStyle(.orange)
                .padding(10)
                .glass(in: Circle())
                .rotationEffect(.radians(a))
                .position(x: g.size.width / 2 + r * sin(a), y: g.size.height * 0.42 - r * cos(a))
                .animation(.easeOut(duration: 0.25), value: a)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// How to scan, in four cards: shown before the first scan, and from the ? button.
struct GuideCards: View {
    var done: () -> Void
    @State private var page = 0

    private static let cards: [(icon: String, title: String, text: String)] = [
        ("figure.walk", "Walk slowly", "Hold the phone upright, about a metre from what you scan, and move at a stroll. A tick in your hand means new surface is coming in."),
        ("paintbrush.pointed", "Paint every surface", "Sweep the floor, the walls and around furniture as if spraying paint. Scanned surfaces get a light tint. Orange means seen too little: go over it again, closer."),
        ("map", "Watch the map", "The map in the corner shows the scan from above, with you on it. Dark patches are gaps. An orange arrow points to a gap that is out of sight."),
        ("checkmark.circle", "Done is not the end", "Done shows the scan to turn around. From there you can scan more, upload it, or keep it on the phone and continue another day."),
    ]

    var body: some View {
        VStack(spacing: 18) {
            TabView(selection: $page) {
                ForEach(Self.cards.indices, id: \.self) { i in
                    VStack(spacing: 16) {
                        Image(systemName: Self.cards[i].icon).font(.system(size: 56, weight: .light)).foregroundStyle(.tint)
                        Text(Self.cards[i].title).font(.title2.weight(.semibold))
                        Text(Self.cards[i].text).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 28)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            Button {
                if page < Self.cards.count - 1 { withAnimation { page += 1 } } else { done() }
            } label: {
                Text(page < Self.cards.count - 1 ? "Next" : "Start scanning").frame(maxWidth: .infinity)
            }
            .glassButton(prominent: true)
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 24)
        .presentationDetents([.medium])
    }
}
