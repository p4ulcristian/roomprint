import SwiftUI

/// The spaces on this phone, and the way to a new one.
struct HomeView: View {
    @EnvironmentObject var store: Store
    @State private var naming = false
    @State private var name = ""
    @State private var pasting = false
    @State private var link = ""
    @State private var busy = false
    @State private var toDelete: SavedSpace?

    var body: some View {
        NavigationStack(path: $store.path) {
            List {
                if store.spaces.isEmpty {
                    ContentUnavailableView("No spaces yet", systemImage: "square.split.bottomrightquarter",
                                           description: Text("A space is a flat, a house floor or anything else you scan. Make one and walk through it with the camera."))
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(store.spaces) { s in
                            NavigationLink(value: s) {
                                Label(s.name, systemImage: "square.split.bottomrightquarter")
                            }
                            .swipeActions {
                                if s.ownerKey != nil {
                                    Button("Delete", role: .destructive) { toDelete = s }
                                } else {
                                    Button("Remove from this phone") { store.forget(s) }.tint(.gray)
                                }
                            }
                        }
                    }
                }
                if let e = store.error {
                    Section { Text(e).foregroundStyle(.red).font(.callout) }
                }
                Section {
                } footer: {
                    Text("Scanning films the walk with sound and records depth, camera positions and small photos. All of it is uploaded to the Roomprint server. Anyone with a space's link can see it. You can delete your spaces here at any time: they are deleted from the server right away, for good.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Backdrop())
            .navigationTitle("Roomprint")
            .navigationDestination(for: SavedSpace.self) { SpaceView(space: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { pasting = true } label: { Label("Open an invite link", systemImage: "link") }
                        Link(destination: URL(string: "\(API.defaultBase)/privacy")!) { Label("Privacy", systemImage: "hand.raised") }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { naming = true } label: {
                    Label(busy ? "Creating…" : "New space", systemImage: "plus")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .glassButton(prominent: true)
                .disabled(busy)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .alert("New space", isPresented: $naming) {
                TextField("Name, e.g. Our flat", text: $name)
                Button("Create") { create() }
                Button("Cancel", role: .cancel) { name = "" }
            } message: {
                Text("What are you scanning?")
            }
            .alert("Open an invite link", isPresented: $pasting) {
                TextField("Paste the link", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Open") { Task { await store.add(link); link = "" } }
                Button("Cancel", role: .cancel) { link = "" }
            }
            .confirmationDialog("Delete “\(toDelete?.name ?? "")”?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                                titleVisibility: .visible, presenting: toDelete) { s in
                Button("Delete from the server", role: .destructive) { Task { _ = await store.delete(s) } }
            } message: { _ in
                Text(SpaceView.deleteMessage)
            }
        }
    }

    private func create() {
        busy = true
        Task {
            await store.create(name)
            name = ""
            busy = false
        }
    }
}
