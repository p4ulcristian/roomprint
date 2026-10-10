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
