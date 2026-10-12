import SwiftUI

/// Asks what to call the person: the whole screen on the app's first start, and a sheet from
/// the menu afterwards. Any name will do. It goes with the spaces this phone makes, so the
/// server's list of every space can tell people apart.
struct NameView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    /// From the menu: there is a name already and a way out without changing it.
    var changing = false
    @State private var name = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "person.crop.circle").font(.system(size: 60)).foregroundStyle(.tint)
            Text(changing ? "Your name" : "What should we call you?").font(.title2.bold())
            Text("Any name will do. It goes with the spaces you make, so the people who run Roomprint can tell them apart from everyone else's. People who open a space's link do not see it.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            TextField("Name", text: $name)
                .textContentType(.nickname)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($typing)
                .onSubmit(save)
                .onChange(of: name) { _, now in
                    if now.count > Person.limit { name = String(now.prefix(Person.limit)) }
                }
                .padding(.horizontal, 18).padding(.vertical, 13)
                .glass(in: Capsule())
            Button(action: save) {
                Text(changing ? "Save" : "Continue").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .glassButton(prominent: true)
            .disabled(Person.clean(name).isEmpty)
            if changing {
                Button("Cancel") { dismiss() }.padding(.top, 2)
            } else {
                Text("You can change it later in the menu.").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
        .background(Backdrop())
        .onAppear {
            name = store.person
            typing = true
        }
    }

    private func save() {
        guard !Person.clean(name).isEmpty else { return }
        store.setPerson(name)
        if changing { dismiss() }
    }
}
