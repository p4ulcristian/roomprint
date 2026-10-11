import SwiftUI

/// One space: its viewer (3D, plan, video, exports) once something has been scanned,
/// scanning, the scans kept on this phone, and its files on the server.
struct SpaceView: View {
    let space: SavedSpace
    @State private var summary: Summary?
    @State private var error: String?
    @State private var capture: KeptScan?
    @State private var kept: [KeptScan] = []
    @State private var showKept = false
    @State private var resume: KeptScan?
    @State private var showFiles = false
    @State private var askDelete = false
    @State private var deleteError: String?
    @StateObject private var files = FileFetcher()
    @EnvironmentObject private var uploader: Uploader
    @EnvironmentObject private var store: Store

    static let deleteMessage = "The floor plan, 3D models, video, depth and every other file of this space are deleted from the server right away, for good. Its link stops working for everyone. There is no undo and no backup."

    /// With the owner key, if this phone made the space.
    private var me: SavedSpace { store.current(space) }

    var body: some View {
        ZStack {
            Backdrop()
            if let s = summary, s.has_space {
                // A new model (mesh, texture, splat) reloads the page.
                ViewerWeb(space: me) { url in Task { await files.fetch(url) } }
                    .id(s.shown)
                    .ignoresSafeArea(edges: .bottom)
            } else if summary != nil {
                empty
            } else if let error {
                ContentUnavailableView("Could not load", systemImage: "wifi.exclamationmark", description: Text(error))
            } else {
                ProgressView()
            }
            if files.busy {
                ProgressView("Getting the file…")
                    .padding(22)
                    .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
        .safeAreaInset(edge: .top) { status }
        .navigationTitle(space.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if summary?.has_space == true || summary?.clips.isEmpty == false || !kept.isEmpty { scanMenu { Image(systemName: "viewfinder") } }
                Menu {
                    ShareLink(item: space.viewerURL) { Label("Share the link", systemImage: "square.and.arrow.up") }
                    Button { showFiles = true } label: { Label("Files on the server", systemImage: "folder") }
                    if me.ownerKey != nil {
                        Divider()
                        Button(role: .destructive) { askDelete = true } label: { Label("Delete this space", systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .task {
            // Poll while the page is open, so processing shows up without pulling to refresh.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .fullScreenCover(item: $capture) { scan in
            CaptureView(space: me, scan: scan) { Task { await load() } }
        }
        .sheet(isPresented: $showKept, onDismiss: {
            // "Continue scanning" opens the camera once the sheet is out of the way.
            if let r = resume { resume = nil; capture = r }
        }) {
            KeptSheet(space: me, scans: kept, onChange: { Task { await load() } }) { scan in
                resume = scan
                showKept = false
            }
        }
        .sheet(isPresented: $showFiles) {
            FilesSheet(space: me, clips: summary?.clips ?? []) { Task { await load() } }
        }
        .sheet(item: $files.fetched) { f in
            if f.isModel { QuickLook(url: f.url).ignoresSafeArea() } else { ShareSheet(url: f.url) }
        }
        .alert("Export", isPresented: Binding(get: { files.error != nil }, set: { if !$0 { files.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(files.error ?? "")
        }
        .confirmationDialog("Delete “\(space.name)”?", isPresented: $askDelete, titleVisibility: .visible) {
            Button("Delete from the server", role: .destructive) {
                Task { if !(await store.delete(space)) { deleteError = store.error } }
            }
        } message: {
            Text(Self.deleteMessage)
        }
        .alert("Could not delete it", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    /// Nothing to show yet: the way to scan, or word that a scan is on its way.
    private var empty: some View {
        let coming = summary?.clips.isEmpty == false || summary?.busy == true || (uploader.progress[space.token]?.total ?? 0) > 0
        return VStack(spacing: 18) {
            Image(systemName: coming ? "arrow.up.circle" : "viewfinder").font(.system(size: 54, weight: .light)).foregroundStyle(.secondary)
            if coming {
                Text("Your scan is on its way").font(.title2.weight(.semibold))
                Text("It appears here as soon as the server has it. You can close the app meanwhile.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            } else if CaptureController.isSupported {
                Text("Nothing scanned yet").font(.title2.weight(.semibold))
                choice("Scan", CaptureController.canPlan
                       ? "A 3D model in real colours and a measured floor plan, from one walk."
                       : "A 3D model in real colours of anything: a room, an object, a garden corner.", "viewfinder")
            } else {
                Text("This phone has no LiDAR").font(.title2.weight(.semibold))
                Text("Scanning needs an iPhone Pro (12 Pro or newer). You can still open spaces others scanned.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            if !kept.isEmpty {
                Button("\(kept.count) scan\(kept.count == 1 ? "" : "s") kept on this phone") { showKept = true }.glassButton()
            }
            if !coming {
                Text("A scan films the walk with sound and records depth and camera positions, and uploads all of it to the Roomprint server.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(24)
    }

    /// Every scan comes with a floor plan where the phone can make one.
    private func scan() {
        capture = ScanStore.new(token: space.token, plan: CaptureController.canPlan)
    }

    private func choice(_ title: String, _ what: String, _ icon: String) -> some View {
        Button { scan() } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(what).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func scanMenu<L: View>(@ViewBuilder label: () -> L) -> some View {
        Menu {
            Button { scan() } label: { Label("Scan", systemImage: "viewfinder") }
            if !kept.isEmpty {
                Divider()
                Button { showKept = true } label: { Label("Scans on this phone (\(kept.count))", systemImage: "iphone") }
            }
        } label: {
            label()
        }
        .disabled(!CaptureController.isSupported)
    }

    /// What the server and the uploads are doing, while they are doing something.
    @ViewBuilder private var status: some View {
        let upload = uploader.progress[space.token].flatMap { $0.total > 0 ? $0 : nil }
        if upload != nil || summary?.busy == true || summary?.status.state == "failed" {
            VStack(alignment: .leading, spacing: 6) {
                if let p = upload {
                    Text("Uploading \(Int(Double(p.sent) / Double(p.total) * 100))% · it goes on with the app closed").font(.footnote)
                    ProgressView(value: Double(p.sent), total: Double(p.total))
                }
                if let s = summary?.status, summary?.busy == true {
                    Text(s.state == "queued" ? "Waiting to start: \(s.step)" : s.step.prefix(1).uppercased() + s.step.dropFirst()).font(.footnote)
                    if s.state == "processing" { ProgressView(value: s.progress) }
                } else if let s = summary?.status, s.state == "failed" {
                    Text("Processing failed: \(s.error ?? s.step)").font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }

    private func load() async {
        kept = ScanStore.list(token: space.token)
        do {
            summary = try await API.summary(base: space.base, token: space.token)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Everything this space has on the server; the phone that made it deletes files here.
struct FilesSheet: View {
    let space: SavedSpace
    let clips: [Summary.Clip]
    var onChange: () -> Void
    @State private var toDelete: Summary.Clip?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if clips.isEmpty { Text("Nothing uploaded yet.").foregroundStyle(.secondary) }
                    ForEach(clips, id: \.id) { c in
                        LabeledContent(Self.kind(c.filename), value: ByteCountFormatter.string(fromByteCount: Int64(c.bytes), countStyle: .file))
                            .swipeActions {
                                if space.ownerKey != nil {
                                    Button("Delete", role: .destructive) { toDelete = c }
                                }
                            }
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.callout) }
                } footer: {
                    Text(space.ownerKey != nil
                         ? "Swipe a file to delete it from the server. Anyone with this space's link can see these."
                         : "Anyone with this space's link can see these. Only the phone that made this space can delete them.")
                }
            }
            .navigationTitle("On the server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Delete this file?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                                titleVisibility: .visible, presenting: toDelete) { c in
                Button("Delete from the server", role: .destructive) { Task { await delete(c) } }
            } message: { c in
                Text(Self.derived(c.filename))
            }
        }
        .presentationDetents([.medium, .large])
    }

    static func kind(_ filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "mov", "mp4", "m4v": return "Video with sound"
        case "roomplan": return "Room scan"
        case "freescan": return "Free scan"
        case "usdz": return "3D model (Apple)"
        case "rgbd": return "Depth and photos"
        case "poses": return "Camera positions"
        default: return filename
        }
    }

    /// What else goes when a file is deleted: the models made from it hold its content.
    static func derived(_ filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "rgbd": return "The depth and photos are deleted from the server right away, for good, and so are the Lidar scan, its photo texture and the splat made from them."
        case "mov", "mp4", "m4v", "poses": return "“\(kind(filename))” is deleted from the server right away, for good, and so are the Lidar scan's photo texture and the splat made from it. The floor plan stays until you delete the space."
        default: return "“\(kind(filename))” is deleted from the server right away, for good. The floor plan made from it stays until you delete the space."
        }
    }

    private func delete(_ c: Summary.Clip) async {
        do {
            try await API.deleteClip(space, id: c.id)
            error = nil
            onChange()
        } catch {
            self.error = "Could not delete it: \(error.localizedDescription)"
        }
    }
}

/// The scans of this space kept on this phone: upload one, continue it, or delete it.
struct KeptSheet: View {
    let space: SavedSpace
    let scans: [KeptScan]
    var onChange: () -> Void
    var onContinue: (KeptScan) -> Void
    @State private var busy: String?
    @State private var error: String?
    @State private var toDelete: KeptScan?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(scans) { s in
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.updated.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text(Self.about(s)).font(.subheadline).foregroundStyle(.secondary)
                            Text(s.uploaded.map { "Uploaded \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Not uploaded yet")
                                .font(.footnote).foregroundStyle(s.uploaded == nil ? .orange : .secondary)
                            if let no = s.noPlan { Text(no).font(.footnote).foregroundStyle(.orange) }
                        }
                        Button { upload(s) } label: {
                            Label(busy == s.id ? "Queueing…" : s.uploaded == nil ? "Upload" : "Upload again", systemImage: "arrow.up.circle")
                        }
                        .disabled(busy != nil)
                        if CaptureController.isSupported {
                            Button { onContinue(s) } label: { Label("Continue scanning", systemImage: "viewfinder") }
                        }
                        Button(role: .destructive) { toDelete = s } label: { Label("Delete from this phone", systemImage: "trash") }
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                Section {} footer: {
                    Text("To continue a scan, start where you can see something you scanned before. Deleting here does not touch what is on the server.")
                }
            }
            .navigationTitle("On this phone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Delete this scan from the phone?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                                titleVisibility: .visible, presenting: toDelete) { s in
                Button("Delete", role: .destructive) {
                    ScanStore.delete(s)
                    onChange()
                }
            } message: { s in
                Text(s.uploaded == nil ? "It was never uploaded, so it is gone for good." : "What was uploaded stays on the server; the scan can no longer be continued.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    static func about(_ s: KeptScan) -> String {
        let t = Int(s.seconds)
        var parts = [String(format: "%d:%02d", t / 60, t % 60), "\(Int(s.area)) m² of surface"]
        if s.rooms > 0 { parts.append("\(s.rooms) room\(s.rooms == 1 ? "" : "s")") }
        if s.segments > 1 { parts.append("continued \(s.segments - 1)×") }
        parts.append(ByteCountFormatter.string(fromByteCount: ScanStore.bytes(s), countStyle: .file))
        return parts.joined(separator: " · ")
    }

    private func upload(_ s: KeptScan) {
        busy = s.id
        Task {
            do {
                try await ScanStore.upload(s, to: space)
                error = nil
            } catch {
                self.error = "Could not queue it: \(error.localizedDescription)"
            }
            busy = nil
            onChange()
        }
    }
}
