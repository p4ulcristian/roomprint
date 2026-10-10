import QuickLook
import SwiftUI
import WebKit

/// The space's viewer (3D, plan, video, files, exports: web/public/viewer.html) inside the
/// app. The page knows it is embedded through window.roomprintApp, which also carries the
/// owner key of spaces this phone made. Links to exports and uploaded files do not
/// navigate: the app downloads them and offers the share sheet, or AR Quick Look for a
/// USDZ model.
struct ViewerWeb: UIViewRepresentable {
    let space: SavedSpace
    var onFile: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let key = (try? JSONSerialization.data(withJSONObject: [space.ownerKey as Any? ?? NSNull()]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[null]"
        config.userContentController.addUserScript(WKUserScript(
            source: "window.roomprintApp = { ownerKey: \(key)[0] };", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.load(URLRequest(url: space.viewerURL))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: ViewerWeb
        init(_ parent: ViewerWeb) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url, action.targetFrame?.isMainFrame != false else { return .allow }
            let path = url.path
            if path.contains("/export/") || (path.contains("/clips/") && path.hasSuffix("/file")) {
                parent.onFile(url)
                return .cancel
            }
            // Anything that is not this space's own page (the privacy page, say) opens in Safari.
            if action.navigationType == .linkActivated, url.path != parent.space.viewerURL.path {
                _ = await UIApplication.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}

/// Fetches an export or an uploaded file to a temporary file, to share or preview.
@MainActor
final class FileFetcher: ObservableObject {
    struct Fetched: Identifiable {
        let url: URL
        var id: String { url.path }
        var isModel: Bool { url.pathExtension.lowercased() == "usdz" }
    }

    @Published var busy = false
    @Published var fetched: Fetched?
    @Published var error: String?

    func fetch(_ remote: URL) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            var req = URLRequest(url: remote)
            req.timeoutInterval = 300   // the server builds an export while we wait
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                let data = (try? Data(contentsOf: tmp)) ?? Data()
                throw APIError(message: API.errorText(data, code))
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)   // only the latest download is kept
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(resp.suggestedFilename ?? remote.lastPathComponent)
            try FileManager.default.moveItem(at: tmp, to: dest)
            fetched = Fetched(url: dest)
        } catch {
            self.error = "Could not get the file: \(error.localizedDescription)"
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Quick Look: a USDZ opens as a 3D model that can be placed in the room in AR.
struct QuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        return UINavigationController(rootViewController: ql)
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
