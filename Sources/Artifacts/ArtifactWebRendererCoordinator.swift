import AppKit
import Foundation
import WebKit

#if DEBUG
private func artifactRendererLog(_ message: @autoclosure () -> String) {
    NSLog("%@", message() as NSString)
}
#endif

/// Coordinates the retained artifact WKWebView and pushes source updates into
/// the bundled renderer shell.
@MainActor
final class ArtifactWebRendererCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    var webView: ArtifactWebView?
    var panelId: UUID = UUID()
    var workspaceId: UUID = UUID()
    var filePath: String = ""

    private var pendingSource: String = ""
    private var pendingKind: ArtifactKind = .react
    private var lastSource: String?
    private var lastKind: ArtifactKind?
    private var isLoaded = false
    private var isShellLoading = false
    private var webContentProcessRecoveryAttempts = 0
    private let maxWebContentProcessRecoveryAttempts = 2
    private var shellWasHealthyWhenDetached = false
    private let cmuxBridge = ArtifactRuntimeCmuxBridge()

    private enum CaptureError: LocalizedError {
        case webViewUnavailable
        case snapshotFailed
        case renderedTextFailed

        var errorDescription: String? {
            switch self {
            case .webViewUnavailable:
                return "Artifact renderer web view is not available"
            case .snapshotFailed:
                return "Failed to capture artifact renderer snapshot"
            case .renderedTextFailed:
                return "Failed to read artifact rendered text"
            }
        }
    }

    func bind(panelId: UUID, workspaceId: UUID, filePath: String) {
        self.panelId = panelId
        self.workspaceId = workspaceId
        self.filePath = filePath
        cmuxBridge.update(panelId: panelId, workspaceId: workspaceId, filePath: filePath, webView: webView)
    }

    func close() {
        if let webView {
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "cmuxArtifactStorage")
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "cmuxArtifactCmux")
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.onPointerDown = nil
            webView.onLeaveWindow = nil
            webView.onReenterWindow = nil
        }
        cmuxBridge.close()
        webView = nil
        isLoaded = false
        isShellLoading = false
        webContentProcessRecoveryAttempts = 0
        shellWasHealthyWhenDetached = false
    }

    func loadShell(initialSource: String, kind: ArtifactKind) {
        cmuxBridge.updateRoomCapability(from: initialSource)
        pendingSource = initialSource
        pendingKind = kind
        lastSource = nil
        lastKind = nil
        isLoaded = false
        isShellLoading = true
        let html = ArtifactViewerAssets.shared.shellHTML()
        let baseURL = URL(fileURLWithPath: filePath)
#if DEBUG
        artifactRendererLog("ArtifactPanel.loadShell filePath=\(filePath) baseURL=\(baseURL.absoluteString) htmlBytes=\(html.utf8.count)")
#endif
        webView?.loadHTMLString(html, baseURL: baseURL)
    }

    func update(source: String, kind: ArtifactKind) {
        cmuxBridge.updateRoomCapability(from: source)
        let contentChanged = lastSource != source || lastKind != kind
        let shellNeedsReload = !isLoaded && !isShellLoading
        guard contentChanged || shellNeedsReload else { return }

        pendingSource = source
        pendingKind = kind

        if contentChanged {
            webContentProcessRecoveryAttempts = 0
            if isLoaded {
                pushArtifact(source: source, kind: kind)
            } else if shellNeedsReload {
                loadShell(initialSource: source, kind: kind)
            }
        } else if shellNeedsReload,
                  webContentProcessRecoveryAttempts < maxWebContentProcessRecoveryAttempts {
            loadShell(initialSource: source, kind: kind)
        }
    }

    func handleViewLeftWindow() {
        shellWasHealthyWhenDetached = isLoaded
    }

    func handleViewReenteredWindow() {
        guard !isLoaded, shellWasHealthyWhenDetached else { return }
        shellWasHealthyWhenDetached = false
        webContentProcessRecoveryAttempts = 0
        loadShell(initialSource: lastSource ?? pendingSource, kind: lastKind ?? pendingKind)
    }

    func captureVisibleSnapshot(completion: @escaping (Result<NSImage, Error>) -> Void) {
        guard let webView else {
            completion(.failure(CaptureError.webViewUnavailable))
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        webView.takeSnapshot(with: configuration) { image, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let image else {
                completion(.failure(CaptureError.snapshotFailed))
                return
            }
            completion(.success(image))
        }
    }

    func renderedText(completion: @escaping (Result<String, Error>) -> Void) {
        guard let webView else {
            completion(.failure(CaptureError.webViewUnavailable))
            return
        }
        let script = """
        (() => String(
          (typeof window.__cmuxArtifactRenderedText === 'function' && window.__cmuxArtifactRenderedText())
          || (document.body && document.body.innerText)
          || ''
        ))()
        """
        webView.evaluateJavaScript(script) { value, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let text = value as? String else {
                completion(.failure(CaptureError.renderedTextFailed))
                return
            }
            completion(.success(text))
        }
    }

    private func pushArtifact(source: String, kind: ArtifactKind) {
        guard let webView else { return }
        let payload: [String: Any] = [
            "source": source,
            "kind": kind.rawValue,
            "filePath": filePath
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
#if DEBUG
        artifactRendererLog("ArtifactPanel.pushArtifact kind=\(kind.rawValue) bytes=\(source.utf8.count)")
#endif
        webView.evaluateJavaScript("window.__cmuxRenderArtifact && window.__cmuxRenderArtifact(\(json));") { [weak self] _, error in
            if let error {
#if DEBUG
                artifactRendererLog("ArtifactPanel: pushArtifact evaluateJavaScript failed: \(error)")
#endif
                return
            }
            self?.lastSource = source
            self?.lastKind = kind
        }
    }

    private func sendStorageResponse(_ response: [String: Any]) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: response),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__cmuxArtifactStorageResolve && window.__cmuxArtifactStorageResolve(\(json));") { _, error in
            if let error {
#if DEBUG
                artifactRendererLog("ArtifactPanel: storage response evaluateJavaScript failed: \(error)")
#endif
            }
        }
    }

    private func sendCmuxResponse(_ response: [String: Any]) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: response),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__cmuxArtifactCmuxResolve && window.__cmuxArtifactCmuxResolve(\(json));") { _, error in
            if let error {
#if DEBUG
                artifactRendererLog("ArtifactPanel: cmux response evaluateJavaScript failed: \(error)")
#endif
            }
        }
    }

    private func handleShellNavigationFailure(for webView: WKWebView, error: Error) {
        guard let currentWebView = self.webView, currentWebView === webView, isShellLoading else { return }
#if DEBUG
        artifactRendererLog("ArtifactPanel.webView.navigationFailed error=\(error)")
#endif
        isShellLoading = false
        isLoaded = false
    }

    private func handleExternalLink(_ url: URL) {
        if let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           BrowserAvailabilitySettings.isEnabled(),
           let app = AppDelegate.shared,
           let location = app.workspaceContainingPanel(
               panelId: panelId,
               preferredWorkspaceId: workspaceId
           ),
           let paneId = location.workspace.paneId(forPanelId: panelId) {
            _ = location.workspace.newBrowserSurface(inPane: paneId, url: url, focus: true)
            return
        }
        NSWorkspace.shared.open(url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
#if DEBUG
        NSLog("ArtifactPanel.webView.didFinish")
#endif
        isShellLoading = false
        isLoaded = true
        let source = lastSource ?? pendingSource
        let kind = lastKind ?? pendingKind
        pushArtifact(source: source, kind: kind)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleShellNavigationFailure(for: webView, error: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleShellNavigationFailure(for: webView, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let currentWebView = self.webView, currentWebView === webView else { return }
#if DEBUG
        NSLog("ArtifactPanel.webView.webContentProcessDidTerminate")
#endif
        isShellLoading = false
        guard webContentProcessRecoveryAttempts < maxWebContentProcessRecoveryAttempts else {
            isLoaded = false
            return
        }
        webContentProcessRecoveryAttempts += 1
        loadShell(initialSource: lastSource ?? pendingSource, kind: lastKind ?? pendingKind)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            handleExternalLink(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            handleExternalLink(url)
        }
        return nil
    }
}

extension ArtifactWebRendererCoordinator: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "cmuxArtifactStorage":
            sendStorageResponse(ArtifactRuntimeStorage.handle(message: message.body))
        case "cmuxArtifactCmux":
            sendCmuxResponse(cmuxBridge.handle(message: message.body))
        default:
            return
        }
    }
}
