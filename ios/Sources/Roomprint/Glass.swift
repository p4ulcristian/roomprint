import SwiftUI

/// The app's look: Liquid Glass where iOS has it (26 and later), the blur material before.
extension View {
    @ViewBuilder func glass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// The soft backdrop the glass floats over; the web pages use the same one.
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            (dark ? Color(red: 0.055, green: 0.075, blue: 0.1) : Color(red: 0.93, green: 0.945, blue: 0.965))
            RadialGradient(colors: [dark ? Color(red: 0.08, green: 0.15, blue: 0.23) : Color(red: 0.875, green: 0.915, blue: 0.97), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [dark ? Color(red: 0.165, green: 0.115, blue: 0.1) : Color(red: 0.965, green: 0.92, blue: 0.895), .clear],
                           center: .trailing, startRadius: 0, endRadius: 460)
        }
        .ignoresSafeArea()
    }
}

/// The round close button on the camera screens.
struct CloseButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44)
        }
        .foregroundStyle(.primary)
        .glass(in: Circle())
        .accessibilityLabel("Close")
    }
}
