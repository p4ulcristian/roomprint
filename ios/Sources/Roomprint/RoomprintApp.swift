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
            if now == .active { Task { await uploader.resume(); await store.claimMissing() } }
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
            let known = spaces.first { $0.token == token }
            let s = SavedSpace(base: base, token: token, name: sum.meta.name, ownerKey: known?.ownerKey)
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

    /// The saved copy of a space (it may have gained its owner key since it was opened).
    func current(_ s: SavedSpace) -> SavedSpace { spaces.first { $0.token == s.token } ?? s }

    /// Forget a space on this phone only; it stays on the server.
    func forget(_ s: SavedSpace) {
        spaces.removeAll { $0.token == s.token }
        save()
    }

    /// Delete a space from the server for good, stop its uploads and forget it here.
    func delete(_ s: SavedSpace) async -> Bool {
        do {
            try await API.deleteSpace(current(s))
            await Uploader.shared.cancel(token: s.token)
            forget(s)
            path.removeAll { $0.token == s.token }
            error = nil
            return true
        } catch {
            self.error = "Could not delete it: \(error.localizedDescription)"
            return false
        }
    }

    /// Spaces this app made before owner keys existed get one, so they can be deleted.
    func claimMissing() async {
        for s in spaces where s.ownerKey == nil && s.base == API.defaultBase {
            guard let key = try? await API.claim(s) else { continue }
            if let i = spaces.firstIndex(where: { $0.token == s.token }) { spaces[i].ownerKey = key }
            save()
        }
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
    @State private var toDelete: SavedSpace?

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
                        ForEach(store.spaces) { s in
                            NavigationLink(s.name, value: s)
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
                Section("Someone sent you a link?") {
                    TextField("Paste an invite link", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await store.add(link); link = "" } }
                }
                Section {
                    Text("Scanning films the walk with sound and records depth and small photos. All of it is uploaded to the Roomprint server. Anyone with a space's link can see it. You can delete your spaces here at any time: they are deleted from the server right away, for good.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link("Privacy", destination: URL(string: "\(API.defaultBase)/privacy")!).font(.footnote)
                }
            }
            .navigationTitle("Roomprint")
            .navigationDestination(for: SavedSpace.self) { SpaceView(space: $0) }
            .confirmationDialog(deleteTitle(toDelete), isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                                titleVisibility: .visible, presenting: toDelete) { s in
                Button("Delete from the server", role: .destructive) { Task { _ = await store.delete(s) } }
            } message: { _ in
                Text(SpaceView.deleteMessage)
            }
        }
    }

    private func deleteTitle(_ s: SavedSpace?) -> String { "Delete “\(s?.name ?? "")”?" }

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
    @State private var askDelete = false
    @State private var clipToDelete: Summary.Clip?
    @State private var deleteError: String?
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var uploader: Uploader
    @EnvironmentObject private var store: Store

    static let deleteMessage = "The floor plan, 3D model, video, depth and every other file of this space are deleted from the server right away, for good. Its link stops working for everyone. There is no undo and no backup."

    /// With the owner key, if this phone made the space.
    private var me: SavedSpace { store.current(space) }

    var body: some View {
        List {
            Section("Status") {
                if let s = summary {
                    LabeledContent("State", value: s.status.state)
                    Text(s.status.step).font(.callout)
                    if s.status.state == "processing" { ProgressView(value: s.status.progress) }
                    if let e = s.status.error { Text(e).foregroundStyle(.red) }
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
            } footer: {
                Text("A scan films the walk with sound and records depth and small photos, and uploads all of it to the Roomprint server.")
            }
            if let clips = summary?.clips, !clips.isEmpty {
                Section {
                    ForEach(clips, id: \.id) { c in
                        LabeledContent(Self.kind(c.filename), value: ByteCountFormatter.string(fromByteCount: Int64(c.bytes), countStyle: .file))
                            .swipeActions {
                                if me.ownerKey != nil {
                                    Button("Delete", role: .destructive) { clipToDelete = c }
                                }
                            }
                    }
                } header: {
                    Text("On the server")
                } footer: {
                    Text(me.ownerKey != nil
                         ? "Swipe a file to delete it from the server. Anyone with this space's link can see these."
                         : "Anyone with this space's link can see these. Only the phone that made this space can delete them.")
                }
            }
            if me.ownerKey != nil {
                Section {
                    Button(role: .destructive) { askDelete = true } label: {
                        Label("Delete this space from the server", systemImage: "trash")
                    }
                    if let deleteError { Text(deleteError).foregroundStyle(.red).font(.callout) }
                }
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
        .confirmationDialog("Delete “\(space.name)”?", isPresented: $askDelete, titleVisibility: .visible) {
            Button("Delete from the server", role: .destructive) {
                Task { if !(await store.delete(space)) { deleteError = store.error } }
            }
        } message: {
            Text(Self.deleteMessage)
        }
        .confirmationDialog("Delete this file?", isPresented: Binding(get: { clipToDelete != nil }, set: { if !$0 { clipToDelete = nil } }),
                            titleVisibility: .visible, presenting: clipToDelete) { c in
            Button("Delete from the server", role: .destructive) { Task { await deleteClip(c) } }
        } message: { c in
            Text(c.filename.lowercased().hasSuffix(".rgbd")
                 ? "The depth and photos are deleted from the server right away, for good, and so is the Real scan 3D model made from them."
                 : "“\(Self.kind(c.filename))” is deleted from the server right away, for good. The floor plan made from it stays until you delete the space.")
        }
    }

    static func kind(_ filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "mov", "mp4", "m4v": return "Video with sound"
        case "roomplan": return "Room scan"
        case "usdz": return "3D model (Apple)"
        case "rgbd": return "Depth and photos"
        default: return filename
        }
    }

    private func deleteClip(_ c: Summary.Clip) async {
        do {
            try await API.deleteClip(me, id: c.id)
            deleteError = nil
            await load()
        } catch {
            deleteError = "Could not delete it: \(error.localizedDescription)"
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
