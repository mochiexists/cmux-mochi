import AppKit
import Foundation

/// v2 `workspace.screenshot`: capture one visible workspace as a single image.
///
/// The window chrome (sidebar, tab bar, dividers, SwiftUI panels) comes from a
/// `cacheDisplay` snapshot of the window content view. Metal-backed terminal
/// portals and WKWebView-backed panes (browser, artifact, native agent
/// sessions) do not render through `cacheDisplay`, so their images are
/// captured through their own snapshot paths and composited on top at their
/// on-screen frames. Runs on the socket worker (see
/// `ControlCommandExecutionPolicy`); UI reads hop to main via `v2MainSync`.
extension TerminalController {
    private struct WorkspaceCaptureOverlay {
        var image: NSImage?
        /// Content-view coordinates, in points, honoring the view's flippedness.
        let rectInContent: CGRect
        let surfaceId: UUID
        let surfaceType: String
        let title: String
        var captureError: String?
    }

    private struct WorkspaceCaptureWebViewRequest {
        let overlayIndex: Int
        let start: (@escaping (Result<NSImage, Error>) -> Void) -> Void
    }

    private struct WorkspaceCaptureContext {
        let workspaceId: UUID
        let workspaceTitle: String
        let windowId: UUID?
        let canvasPointSize: CGSize
        let contentIsFlipped: Bool
        let baseImage: NSImage
        var overlays: [WorkspaceCaptureOverlay]
        let webViewRequests: [WorkspaceCaptureWebViewRequest]
    }

    nonisolated func v2WorkspaceScreenshot(params: [String: Any]) -> V2CallResult {
        let encodingResult = v2SurfaceImageEncoding(params: params)
        if let error = encodingResult.error {
            return error
        }
        guard let encoding = encodingResult.encoding else {
            return .err(code: "internal_error", message: "Image encoding setup failed", data: nil)
        }
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var contextResult: Result<WorkspaceCaptureContext, V2CallResult>?
        v2MainSync {
            contextResult = self.workspaceCaptureContext(params: params, tabManager: tabManager)
        }
        guard let contextResult else {
            return .err(code: "internal_error", message: "Workspace capture setup failed", data: nil)
        }

        var context: WorkspaceCaptureContext
        switch contextResult {
        case .failure(let error):
            return error
        case .success(let value):
            context = value
        }

        // WebKit snapshots complete via main-queue callbacks, so they must be
        // awaited from the worker lane, one at a time, outside v2MainSync.
        for request in context.webViewRequests {
            let snapshot: Result<NSImage, Error>? = v2AwaitCallback(timeout: 10.0) { finish in
                v2MainSync {
                    request.start(finish)
                }
            }
            switch snapshot {
            case .success(let image):
                context.overlays[request.overlayIndex].image = image
            case .failure(let error):
                context.overlays[request.overlayIndex].captureError = error.localizedDescription
            case nil:
                context.overlays[request.overlayIndex].captureError = "Timed out waiting for snapshot"
            }
        }

        guard let composed = composeWorkspaceCapture(context: context),
              let encodedImage = v2EncodeSurfaceImage(composed, encoding: encoding) else {
            return .err(code: "internal_error", message: "Failed to compose workspace snapshot", data: nil)
        }

        var result: [String: Any] = [
            "workspace_id": context.workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: context.workspaceId),
            "workspace_title": context.workspaceTitle,
            "window_id": v2OrNull(context.windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: context.windowId),
            "pane_rect_space": "original_image_pixels_top_left",
            "panes": workspaceCapturePanesPayload(context: context)
        ]
        v2AttachEncodedSurfaceImage(encodedImage, to: &result, includeBase64: v2Bool(params, "include_base64") ?? true)

        let screenshotsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workspace-screenshots", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)) != nil {
            bestEffortPruneTemporaryFiles(in: screenshotsDirectory)
            let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
            let shortWorkspaceId = String(context.workspaceId.uuidString.prefix(8))
            let shortRandomId = String(UUID().uuidString.prefix(8))
            let filename = "workspace-\(shortWorkspaceId)-\(timestampMs)-\(shortRandomId).\(encodedImage.format.fileExtension)"
            let imageURL = screenshotsDirectory.appendingPathComponent(filename, isDirectory: false)
            if (try? encodedImage.data.write(to: imageURL, options: .atomic)) != nil {
                result["path"] = imageURL.path
                result["url"] = imageURL.absoluteString
            }
        }

        return .ok(result)
    }

    @MainActor
    private func workspaceCaptureContext(
        params: [String: Any],
        tabManager: TabManager
    ) -> Result<WorkspaceCaptureContext, V2CallResult> {
        guard let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
            return .failure(.err(code: "not_found", message: "Workspace not found", data: nil))
        }
        guard tabManager.selectedTabId == workspace.id else {
            return .failure(.err(
                code: "not_visible",
                message: "Workspace is not the selected workspace in its window; select it first (workspace capture never changes focus)",
                data: ["workspace_id": workspace.id.uuidString]
            ))
        }
        guard let window = AppDelegate.shared?.mainWindowContainingWorkspace(workspace.id),
              let contentView = window.contentView,
              !contentView.bounds.isEmpty else {
            return .failure(.err(
                code: "not_visible",
                message: "No visible window is displaying this workspace",
                data: ["workspace_id": workspace.id.uuidString]
            ))
        }

        let bounds = contentView.bounds
        guard let baseBitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            return .failure(.err(code: "internal_error", message: "Window snapshot capture unavailable", data: nil))
        }
        contentView.cacheDisplay(in: bounds, to: baseBitmap)
        let baseImage = NSImage(size: bounds.size)
        baseImage.addRepresentation(baseBitmap)

        var overlays: [WorkspaceCaptureOverlay] = []
        var webViewRequests: [WorkspaceCaptureWebViewRequest] = []

        func contentRect(forViewInWindowSpace rectInWindow: CGRect) -> CGRect {
            contentView.convert(rectInWindow, from: nil)
        }

        func appendWebViewOverlay(
            surfaceId: UUID,
            surfaceType: String,
            title: String,
            view: NSView?,
            start: @escaping (@escaping (Result<NSImage, Error>) -> Void) -> Void
        ) {
            guard let view,
                  view.window === window,
                  !view.isHiddenOrHasHiddenAncestor else {
                return
            }
            let rect = contentRect(forViewInWindowSpace: view.convert(view.bounds, to: nil))
            guard !rect.isEmpty, rect.intersects(bounds) else { return }
            overlays.append(WorkspaceCaptureOverlay(
                image: nil,
                rectInContent: rect,
                surfaceId: surfaceId,
                surfaceType: surfaceType,
                title: title
            ))
            webViewRequests.append(WorkspaceCaptureWebViewRequest(overlayIndex: overlays.count - 1, start: start))
        }

        for (panelId, panel) in workspace.panels {
            if let terminalPanel = panel as? TerminalPanel {
                let hostedView = terminalPanel.hostedView
                guard terminalPanel.surface.isViewInWindow,
                      hostedView.debugPortalVisibleInUI,
                      hostedView.window === window else {
                    continue
                }
                let rect = contentRect(forViewInWindowSpace: hostedView.debugPortalFrameInWindow)
                guard !rect.isEmpty, rect.intersects(bounds) else { continue }
                var cgImage = hostedView.debugCopyIOSurfaceCGImage()
                if cgImage == nil {
                    terminalPanel.surface.forceRefresh(reason: "terminalController.workspaceScreenshotRetry")
                    cgImage = hostedView.debugCopyIOSurfaceCGImage()
                }
                overlays.append(WorkspaceCaptureOverlay(
                    image: cgImage.map { self.v2Image(from: $0) },
                    rectInContent: rect,
                    surfaceId: panelId,
                    surfaceType: panel.panelType.rawValue,
                    title: panel.displayTitle,
                    captureError: cgImage == nil ? "Terminal surface image unavailable" : nil
                ))
            } else if let browserPanel = panel as? BrowserPanel {
                appendWebViewOverlay(
                    surfaceId: panelId,
                    surfaceType: panel.panelType.rawValue,
                    title: panel.displayTitle,
                    view: browserPanel.webView
                ) { finish in
                    browserPanel.captureAutomationVisibleViewportSnapshot(completion: finish)
                }
            } else if let agentPanel = panel as? AgentSessionPanel {
                appendWebViewOverlay(
                    surfaceId: panelId,
                    surfaceType: panel.panelType.rawValue,
                    title: panel.displayTitle,
                    view: agentPanel.rendererSession.captureView
                ) { finish in
                    agentPanel.rendererSession.captureVisibleSnapshot(completion: finish)
                }
            } else if let artifactPanel = panel as? ArtifactPanel {
                appendWebViewOverlay(
                    surfaceId: panelId,
                    surfaceType: panel.panelType.rawValue,
                    title: panel.displayTitle,
                    view: artifactPanel.rendererSession.captureView
                ) { finish in
                    artifactPanel.rendererSession.captureVisibleSnapshot(completion: finish)
                }
            }
            // Other panel types (markdown, task manager, project, …) are
            // SwiftUI-rendered and already present in the cacheDisplay base.
        }

        return .success(WorkspaceCaptureContext(
            workspaceId: workspace.id,
            workspaceTitle: workspace.title,
            windowId: AppDelegate.shared?.windowId(for: tabManager),
            canvasPointSize: bounds.size,
            contentIsFlipped: contentView.isFlipped,
            baseImage: baseImage,
            overlays: overlays,
            webViewRequests: webViewRequests
        ))
    }

    /// Bottom-left-origin drawing rect for an overlay, in canvas points.
    private nonisolated func workspaceCaptureDrawRect(
        _ rect: CGRect,
        canvasPointSize: CGSize,
        contentIsFlipped: Bool
    ) -> CGRect {
        guard contentIsFlipped else { return rect }
        return CGRect(
            x: rect.minX,
            y: canvasPointSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Top-left-origin metadata rect for an overlay, in canvas points.
    private nonisolated func workspaceCaptureTopLeftRect(
        _ rect: CGRect,
        canvasPointSize: CGSize,
        contentIsFlipped: Bool
    ) -> CGRect {
        guard !contentIsFlipped else { return rect }
        return CGRect(
            x: rect.minX,
            y: canvasPointSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private nonisolated func composeWorkspaceCapture(context: WorkspaceCaptureContext) -> NSImage? {
        let pointSize = context.canvasPointSize
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }
        let pixelSize = workspaceCapturePixelSize(context: context)
        let scaleX = CGFloat(pixelSize.width) / pointSize.width
        let scaleY = CGFloat(pixelSize.height) / pointSize.height

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize.width,
            pixelsHigh: pixelSize.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        if let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.current = graphicsContext
            graphicsContext.imageInterpolation = .high
            let canvasRect = NSRect(x: 0, y: 0, width: CGFloat(pixelSize.width), height: CGFloat(pixelSize.height))
            NSColor.black.setFill()
            canvasRect.fill()
            context.baseImage.draw(in: canvasRect, from: .zero, operation: .sourceOver, fraction: 1)
            for overlay in context.overlays {
                guard let image = overlay.image else { continue }
                let pointRect = workspaceCaptureDrawRect(
                    overlay.rectInContent,
                    canvasPointSize: pointSize,
                    contentIsFlipped: context.contentIsFlipped
                )
                let pixelRect = NSRect(
                    x: pointRect.minX * scaleX,
                    y: pointRect.minY * scaleY,
                    width: pointRect.width * scaleX,
                    height: pointRect.height * scaleY
                )
                image.draw(in: pixelRect, from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        let composed = NSImage(size: NSSize(width: pixelSize.width, height: pixelSize.height))
        composed.addRepresentation(bitmap)
        return composed
    }

    private nonisolated func workspaceCapturePixelSize(context: WorkspaceCaptureContext) -> (width: Int, height: Int) {
        for representation in context.baseImage.representations
        where representation.pixelsWide > 0 && representation.pixelsHigh > 0 {
            return (representation.pixelsWide, representation.pixelsHigh)
        }
        return (
            max(1, Int(context.canvasPointSize.width.rounded())),
            max(1, Int(context.canvasPointSize.height.rounded()))
        )
    }

    private nonisolated func workspaceCapturePanesPayload(context: WorkspaceCaptureContext) -> [[String: Any]] {
        let pixelSize = workspaceCapturePixelSize(context: context)
        let scaleX = CGFloat(pixelSize.width) / max(context.canvasPointSize.width, 1)
        let scaleY = CGFloat(pixelSize.height) / max(context.canvasPointSize.height, 1)
        return context.overlays
            .sorted { lhs, rhs in
                let left = workspaceCaptureTopLeftRect(
                    lhs.rectInContent, canvasPointSize: context.canvasPointSize, contentIsFlipped: context.contentIsFlipped
                )
                let right = workspaceCaptureTopLeftRect(
                    rhs.rectInContent, canvasPointSize: context.canvasPointSize, contentIsFlipped: context.contentIsFlipped
                )
                if left.minY != right.minY { return left.minY < right.minY }
                return left.minX < right.minX
            }
            .map { overlay in
                let topLeft = workspaceCaptureTopLeftRect(
                    overlay.rectInContent,
                    canvasPointSize: context.canvasPointSize,
                    contentIsFlipped: context.contentIsFlipped
                )
                var pane: [String: Any] = [
                    "surface_id": overlay.surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: overlay.surfaceId),
                    "surface_type": overlay.surfaceType,
                    "title": overlay.title,
                    "captured": overlay.image != nil,
                    "rect": [
                        "x": Int((topLeft.minX * scaleX).rounded()),
                        "y": Int((topLeft.minY * scaleY).rounded()),
                        "width": Int((topLeft.width * scaleX).rounded()),
                        "height": Int((topLeft.height * scaleY).rounded())
                    ]
                ]
                if let captureError = overlay.captureError {
                    pane["capture_error"] = captureError
                }
                return pane
            }
    }
}
