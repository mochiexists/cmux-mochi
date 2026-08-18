import AppKit
import SwiftUI
import WebKit

/// SwiftUI bridge for the artifact WKWebView renderer.
struct ArtifactWebRenderer: NSViewRepresentable {
    let source: String
    let kind: ArtifactKind
    let backgroundColor: NSColor
    let panelId: UUID
    let workspaceId: UUID
    let filePath: String
    let session: ArtifactRendererSession
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> ArtifactWebRendererCoordinator {
        session.coordinator(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
    }

    func makeNSView(context: Context) -> WKWebView {
        if let webView = context.coordinator.webView {
            if webView.superview != nil {
                webView.removeFromSuperview()
            }
            configure(webView: webView, coordinator: context.coordinator)
            return webView
        }

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        config.userContentController = WKUserContentController()
        config.userContentController.add(context.coordinator, name: "cmuxArtifactStorage")
        config.userContentController.add(context.coordinator, name: "cmuxArtifactCmux")
        let webView = ArtifactWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        if #available(macOS 13.3, *) {
#if DEBUG
            webView.isInspectable = true
#else
            webView.isInspectable = false
#endif
        }

        context.coordinator.webView = webView
        context.coordinator.bind(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
        configure(webView: webView, coordinator: context.coordinator)
        context.coordinator.loadShell(initialSource: source, kind: kind)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.bind(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
        if let webView = nsView as? ArtifactWebView {
            configure(webView: webView, coordinator: context.coordinator)
        } else {
            applyBackground(to: nsView)
        }
        context.coordinator.update(source: source, kind: kind)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: ArtifactWebRendererCoordinator) {
        if let retainedWebView = coordinator.webView, retainedWebView === nsView {
            return
        }
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        (nsView as? ArtifactWebView)?.onPointerDown = nil
        (nsView as? ArtifactWebView)?.onLeaveWindow = nil
        (nsView as? ArtifactWebView)?.onReenterWindow = nil
    }

    private func configure(webView: ArtifactWebView, coordinator: ArtifactWebRendererCoordinator) {
        webView.onPointerDown = onRequestPanelFocus
        webView.onLeaveWindow = { [weak coordinator] in
            coordinator?.handleViewLeftWindow()
        }
        webView.onReenterWindow = { [weak coordinator] in
            coordinator?.handleViewReenteredWindow()
        }
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        applyBackground(to: webView)
    }

    private func applyBackground(to webView: WKWebView) {
        webView.underPageBackgroundColor = backgroundColor
        webView.wantsLayer = true
        webView.layer?.backgroundColor = backgroundColor.cgColor
        webView.layer?.isOpaque = backgroundColor.alphaComponent >= 0.999
    }
}
