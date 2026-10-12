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
            Group {
                // The first start asks for a name before anything else; there is no way round it.
                if store.person.isEmpty { NameView() } else { HomeView() }
            }
            .environmentObject(store)
            .environmentObject(uploader)
            // roomprint://u/<token>, from the "Open in the app" button on the upload page
            .onOpenURL { url in Task { await store.add(url.absoluteString) } }
        }
        // Uploads queued while offline, or cut off by a force quit, go on from here.
        .onChange(of: phase) { _, now in
            if now == .active { Task { await uploader.resume(); await store.claimMissing(); await store.tellDevice() } }
        }
    }
}

/// The invite links this phone has opened, newest first.
@MainActor
final class Store: ObservableObject {
    @Published var spaces: [SavedSpace] = []
    @Published var path: [SavedSpace] = []
    @Published var error: String?
    /// The name picked on the first start; empty until then.
    @Published private(set) var person = Person.name
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

    /// A new space, named by the day and its number on that day: "11 Oct · 2".
    func create() async {
        let day = Date().formatted(.dateTime.day().month(.abbreviated))
        let last = spaces.compactMap { s -> Int? in
            guard s.name.hasPrefix("\(day) · ") else { return nil }
            return Int(s.name.dropFirst(day.count + 3))
        }.max() ?? 0
        do {
            let s = try await API.createSpace(name: "\(day) · \(last + 1)")
            spaces.insert(s, at: 0)
            save()
            told(s.token, as: person)
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

    /// The name from the first start, or a new one from the menu. The spaces already made
    /// are told about it too.
    func setPerson(_ name: String) {
        Person.name = name
        person = Person.name
        Task { await tellDevice() }
    }

    /// Every space this phone made is marked on the server as this phone's, under the
    /// person's name: once for each space, and again when the name changes.
    func tellDevice() async {
        let name = person
        guard !name.isEmpty else { return }
        let done = UserDefaults.standard.dictionary(forKey: toldKey) as? [String: String] ?? [:]
        for s in spaces where s.ownerKey != nil && s.base == API.defaultBase && done[s.token] != name {
            guard (try? await API.tellDevice(s)) != nil else { continue }
            told(s.token, as: name)
        }
    }

    /// Which name the server has for each space, by the space's token.
    private let toldKey = "personTold"
    private func told(_ token: String, as name: String) {
        var done = UserDefaults.standard.dictionary(forKey: toldKey) as? [String: String] ?? [:]
        done[token] = name
        UserDefaults.standard.set(done, forKey: toldKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(spaces) { UserDefaults.standard.set(data, forKey: key) }
    }
}
