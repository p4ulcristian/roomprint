import RoomPlan
import SwiftUI

@main
struct RoomprintApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store()
    @StateObject private var uploader = Uploader.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .environmentObject(uploader)
                // roomprint://u/<token>, from the "Open in the app" button on the upload page
                .onOpenURL { url in Task { await store.add(url.absoluteString) } }
        }
        // Uploads queued while offline, or cut off by a force quit, go on from here.
        .onChange(of: phase) { _, now in
            if now == .active { Task { await uploader.resume() } }
        }
    }
}

/// The invite links this phone has opened, newest first.
@MainActor
final class Store: ObservableObject {
    @Published var spaces: [SavedSpace] = []
    @Published var path: [SavedSpace] = []
    @Published var error: String?
    private let key = "spaces"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([SavedSpace].self, from: data) {
            spaces = saved
        }
    }

    func add(_ text: String) async {
        guard let (base, token) = API.parseInvite(text) else {
            error = "That doesn't look like a Roomprint link."
            return
        }
        do {
            let sum = try await API.summary(base: base, token: token)
            let s = SavedSpace(base: base, token: token, name: sum.meta.name)
            spaces.removeAll { $0.token == token }
            spaces.insert(s, at: 0)
            save()
            error = nil
            path = [s]
        } catch {
            self.error = error.localizedDescription
        }
    }

    func create(_ name: String) async {
        do {
            let s = try await API.createSpace(name: name.trimmingCharacters(in: .whitespaces))
            spaces.insert(s, at: 0)
            save()
            error = nil
            path = [s]
        } catch {
            self.error = error.localizedDescription
        }
    }

    func remove(at offsets: IndexSet) {
        spaces.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(spaces) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct HomeView: View {
    @EnvironmentObject var store: Store
    @State private var name = ""
    @State private var link = ""
    @State private var busy = false

    var body: some View {
        NavigationStack(path: $store.path) {
            List {
                Section("New space") {
                    TextField("Name, e.g. Our flat", text: $name)
                        .onSubmit(create)
                    Button(action: create) {
                        Label(busy ? "Creating…" : "Create and scan", systemImage: "plus")
                    }
                    .disabled(busy)
                    if let e = store.error { Text(e).foregroundStyle(.red).font(.callout) }
                }
                if !store.spaces.isEmpty {
                    Section("Spaces") {
                        ForEach(store.spaces) { s in NavigationLink(s.name, value: s) }
                            .onDelete { store.remove(at: $0) }
                    }
                }
                Section("Someone sent you a link?") {
                    TextField("Paste an invite link", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await store.add(link); link = "" } }
                }
            }
            .navigationTitle("Roomprint")
            .navigationDestination(for: SavedSpace.self) { SpaceView(space: $0) }
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

struct SpaceView: View {
    let space: SavedSpace
    @State private var summary: Summary?
    @State private var error: String?
    @State private var scanning = false
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var uploader: Uploader

    var body: some View {
        List {
            Section("Status") {
                if let s = summary {
                    LabeledContent("State", value: s.status.state)
                    Text(s.status.step).font(.callout)
                    if s.status.state == "processing" { ProgressView(value: s.status.progress) }
                    if let e = s.status.error { Text(e).foregroundStyle(.red) }
                    LabeledContent("Uploads", value: "\(s.clips.count)")
                    if let p = uploader.progress[space.token], p.total > 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Uploading in the background: \(Int(Double(p.sent) / Double(p.total) * 100))%")
                                .font(.callout)
                            ProgressView(value: Double(p.sent), total: Double(p.total))
                            Text("You can close the app; it goes on by itself.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
            }
            Section {
                if RoomCaptureSession.isSupported {
                    Button { scanning = true } label: { Label("Scan rooms with LiDAR", systemImage: "viewfinder") }
                        .disabled(["queued", "processing"].contains(summary?.status.state ?? ""))
                } else {
                    Text("This phone has no LiDAR, so room scanning is not available.")
                }
                Button { openURL(space.viewerURL) } label: { Label("Open the floor plan", systemImage: "map") }
                    .disabled(summary?.has_space != true)
            }
        }
        .navigationTitle(space.name)
        .refreshable { await load() }
        .task {
            // Poll while the page is open, so processing shows up without pulling to refresh.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .fullScreenCover(isPresented: $scanning) {
            ScanView(space: space) { Task { await load() } }
        }
    }

    private func load() async {
        do {
            summary = try await API.summary(base: space.base, token: space.token)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
