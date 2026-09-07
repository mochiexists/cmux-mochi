import AppKit
import Foundation
import WebKit

// MARK: - Surface capture socket commands

// Fork (cmux Mochi): `surface.screenshot`, `surface.ingest`, and `surface.text`.
// ControlCommandExecutionPolicy routes all three to the socket worker, but the
// rebase dropped their implementations, so each answered method_not_found.
//
// Two deliberate deviations from the shipping line:
//  - the ArtifactPanel capture/text branches are omitted, since the Artifacts
//    panel is not present on this trunk
//  - `surface.read_text` is not routed here: this trunk keeps its own
//    v2SurfaceReadText, a different implementation from the fork's v2SurfaceText

extension TerminalController {

    nonisolated private static func readUTF8ishFile(path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private struct V2SurfacePanelContext {
        let windowId: UUID?
        let workspaceId: UUID
        let surfaceId: UUID
        let surfaceType: String
        let title: String
        let terminalPanel: TerminalPanel?
        let browserPanel: BrowserPanel?
        let browserWebView: WKWebView?
        let markdownPanel: MarkdownPanel?
        let filePreviewPanel: FilePreviewPanel?
    }

    private nonisolated static func conductorAuditRootURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("conductor", isDirectory: true)
            .appendingPathComponent("audit", isDirectory: true)
    }

    private nonisolated static func iso8601String(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private nonisolated static func auditDatePathComponents(_ date: Date) -> [String] {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone.current, from: date)
        return [
            String(format: "%04d", components.year ?? 1970),
            String(format: "%02d", components.month ?? 1),
            String(format: "%02d", components.day ?? 1)
        ]
    }

    nonisolated func v2SurfaceCommandOnSocketWorker(method: String, params: [String: Any]) -> V2CallResult {
        switch method {
        case "surface.screenshot":
            return v2SurfaceScreenshot(params: params)
        case "surface.ingest":
            return v2SurfaceIngest(params: params)
        case "surface.text":
            return v2SurfaceText(params: params)
        default:
            return .err(code: "invalid_dispatch", message: "Unhandled socket-worker surface method \(method)", data: nil)
        }
    }

    private nonisolated func v2SurfaceScreenshot(params: [String: Any]) -> V2CallResult {
        let encodingResult = v2SurfaceImageEncoding(params: params)
        if let error = encodingResult.error {
            return error
        }
        guard let encoding = encodingResult.encoding else {
            return .err(code: "internal_error", message: "Image encoding setup failed", data: nil)
        }

        let resolved = v2SurfacePanelContext(params: params)
        if let error = resolved.error {
            return error
        }
        guard let ctx = resolved.context else {
            return .err(code: "internal_error", message: "Surface operation failed", data: nil)
        }

        let capturedImage: NSImage?
        if let terminalPanel = ctx.terminalPanel {
            capturedImage = v2MainSync {
                var cgImage = terminalPanel.hostedView.debugCopyIOSurfaceCGImage()
                if cgImage == nil {
                    terminalPanel.surface.forceRefresh(reason: "terminalController.surfaceScreenshotRetry")
                    cgImage = terminalPanel.hostedView.debugCopyIOSurfaceCGImage()
                }
                guard let cgImage else { return nil }
                return self.v2Image(from: cgImage)
            }
        } else if let browserPanel = ctx.browserPanel {
            let snapshotResult: NSImage?? = v2AwaitCallback(timeout: 15.0) { finish in
                v2MainSync {
                    browserPanel.captureAutomationVisibleViewportSnapshot { result in
                        switch result {
                        case .success(let image):
                            finish(image)
                        case .failure:
                            finish(nil)
                        }
                    }
                }
            }
            guard let snapshotResult else {
                return .err(code: "timeout", message: "Timed out waiting for snapshot", data: nil)
            }
            guard let snapshotImage = snapshotResult else {
                return .err(code: "internal_error", message: "Failed to capture snapshot", data: nil)
            }
            capturedImage = snapshotImage
        } else {
            return .err(
                code: "not_supported",
                message: "Surface type does not support screenshots yet",
                data: ["surface_id": ctx.surfaceId.uuidString, "surface_type": ctx.surfaceType]
            )
        }

        guard let capturedImage,
              let encodedImage = v2EncodeSurfaceImage(capturedImage, encoding: encoding) else {
            return .err(code: "internal_error", message: "Failed to encode snapshot", data: nil)
        }

        var result = v2SurfaceBasePayload(ctx)
        v2AttachEncodedSurfaceImage(encodedImage, to: &result, includeBase64: v2Bool(params, "include_base64") ?? true)

        let screenshotsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-surface-screenshots", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)) != nil {
            bestEffortPruneTemporaryFiles(in: screenshotsDirectory)
            let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
            let shortSurfaceId = String(ctx.surfaceId.uuidString.prefix(8))
            let shortRandomId = String(UUID().uuidString.prefix(8))
            let safeType = ctx.surfaceType.replacingOccurrences(of: "/", with: "-")
            let filename = "\(safeType)-\(shortSurfaceId)-\(timestampMs)-\(shortRandomId).\(encodedImage.format.fileExtension)"
            let imageURL = screenshotsDirectory.appendingPathComponent(filename, isDirectory: false)
            if (try? encodedImage.data.write(to: imageURL, options: .atomic)) != nil {
                result["path"] = imageURL.path
                result["url"] = imageURL.absoluteString
            }
        }

        if v2Bool(params, "audit") == true,
           let audit = v2MaterializeSurfaceAudit(
               payload: result,
               image: encodedImage,
               text: nil,
               textSource: nil,
               reason: v2String(params, "audit_reason") ?? "surface.screenshot"
           ) {
            result["audit"] = audit
        }

        return .ok(result)
    }

    private nonisolated func v2SurfaceIngest(params: [String: Any]) -> V2CallResult {
        let includeText = v2Bool(params, "include_text") ?? true
        let includeScreenshot = v2Bool(params, "include_screenshot") ?? true
        let includeBase64 = v2Bool(params, "include_base64") ?? false
        let auditEnabled = v2Bool(params, "audit") ?? true

        var textPayload: [String: Any]?
        var textError: [String: Any]?
        if includeText {
            var textParams = params
            if textParams["lines"] == nil && textParams["line_limit"] == nil {
                textParams["lines"] = 200
            }
            if textParams["scrollback"] == nil {
                textParams["scrollback"] = true
            }
            switch v2SurfaceText(params: textParams) {
            case .ok(let payload):
                textPayload = payload as? [String: Any]
            case .err(let code, let message, let data):
                textError = ["code": code, "message": message, "data": data ?? NSNull()]
            }
        }

        var screenshotPayload: [String: Any]?
        var screenshotError: [String: Any]?
        var encodedImage: V2EncodedSurfaceImage?
        if includeScreenshot {
            var screenshotParams = params
            if screenshotParams["profile"] == nil {
                screenshotParams["profile"] = "llm"
            }
            if screenshotParams["format"] == nil && screenshotParams["image_format"] == nil {
                screenshotParams["format"] = "png"
            }
            if screenshotParams["max_dimension"] == nil &&
                screenshotParams["maxDimension"] == nil &&
                screenshotParams["max_image_dimension"] == nil {
                screenshotParams["max_dimension"] = 2048
            }
            screenshotParams["include_base64"] = true
            screenshotParams["audit"] = false
            switch v2SurfaceScreenshot(params: screenshotParams) {
            case .ok(let payload):
                if let dict = payload as? [String: Any] {
                    screenshotPayload = dict
                    encodedImage = v2EncodedSurfaceImage(from: dict)
                }
            case .err(let code, let message, let data):
                screenshotError = ["code": code, "message": message, "data": data ?? NSNull()]
            }
        }

        guard textPayload != nil || screenshotPayload != nil else {
            var errorData: [String: Any] = [:]
            if let textError {
                errorData["text_error"] = textError
            }
            if let screenshotError {
                errorData["screenshot_error"] = screenshotError
            }
            return .err(
                code: "not_supported",
                message: "Surface does not support text or screenshot ingest",
                data: errorData
            )
        }

        let basePayload = screenshotPayload ?? textPayload ?? [:]
        var result = v2SurfaceBasePayloadFromPayload(basePayload)

        var sanitizedScreenshotPayload = screenshotPayload
        if includeBase64 == false {
            sanitizedScreenshotPayload?.removeValue(forKey: "png_base64")
            sanitizedScreenshotPayload?.removeValue(forKey: "jpeg_base64")
        }

        var sanitizedTextPayload = textPayload
        if sanitizedTextPayload != nil {
            sanitizedTextPayload?.removeValue(forKey: "base64")
        }

        let textValue = textPayload?["text"] as? String
        let textSource = textPayload?["source"] as? String

        if auditEnabled {
            var auditPayload = result
            if let sanitizedScreenshotPayload {
                auditPayload["screenshot"] = sanitizedScreenshotPayload
            }
            if let sanitizedTextPayload {
                var textMetadata = sanitizedTextPayload
                textMetadata.removeValue(forKey: "text")
                auditPayload["text"] = textMetadata
            }
            if let audit = v2MaterializeSurfaceAudit(
                payload: auditPayload,
                image: encodedImage,
                text: textValue,
                textSource: textSource,
                reason: v2String(params, "audit_reason") ?? "surface.ingest"
            ) {
                result["audit"] = audit
                if let imagePath = audit["image_path"] as? String {
                    sanitizedScreenshotPayload?["path"] = imagePath
                    sanitizedScreenshotPayload?["url"] = URL(fileURLWithPath: imagePath).absoluteString
                }
                if let textPath = audit["text_path"] as? String {
                    sanitizedTextPayload?["text_path"] = textPath
                    sanitizedTextPayload?["text_url"] = URL(fileURLWithPath: textPath).absoluteString
                }
            }
        }

        if let sanitizedTextPayload {
            result["text"] = sanitizedTextPayload
        }
        if let sanitizedScreenshotPayload {
            result["screenshot"] = sanitizedScreenshotPayload
        }
        if let textError {
            result["text_error"] = textError
        }
        if let screenshotError {
            result["screenshot_error"] = screenshotError
        }
        result["prompt"] = v2SurfaceIngestPromptBlock(
            surfacePayload: result,
            screenshotPayload: sanitizedScreenshotPayload,
            textPayload: sanitizedTextPayload
        )
        result["llm_guidance"] = [
            "prefer_text": true,
            "use_image_for": ["layout", "visual_state", "ocr_gaps"],
            "default_profile": "llm",
            "default_max_dimension": 2048
        ]
        return .ok(result)
    }

    private nonisolated func v2SurfaceText(params: [String: Any]) -> V2CallResult {
        let includeScrollback = v2Bool(params, "scrollback") ?? false
        let lineLimit = v2Int(params, "lines") ?? v2Int(params, "line_limit")
        if let lineLimit, lineLimit <= 0 {
            return .err(code: "invalid_params", message: "lines must be greater than 0", data: nil)
        }

        let resolved = v2SurfacePanelContext(params: params)
        if let error = resolved.error {
            return error
        }
        guard let ctx = resolved.context else {
            return .err(code: "internal_error", message: "Surface operation failed", data: nil)
        }

        let text: String
        let source: String
        if let terminalPanel = ctx.terminalPanel {
            let snapshot = v2MainSync {
                readTerminalTextRawSnapshot(terminalPanel: terminalPanel, includeScrollback: includeScrollback || lineLimit != nil)
            }
            guard let snapshot else {
                return .err(code: "internal_error", message: "Failed to read terminal text", data: nil)
            }
            switch Self.terminalTextPayload(
                from: snapshot,
                includeScrollback: includeScrollback || lineLimit != nil,
                lineLimit: lineLimit
            ) {
            case .success(let payload):
                text = payload.text
                source = includeScrollback || lineLimit != nil ? "terminal_scrollback" : "terminal_viewport"
            case .failure(let error):
                return .err(code: "internal_error", message: error.message, data: nil)
            }
        } else if ctx.browserPanel != nil, let browserWebView = ctx.browserWebView {
            let selector = v2String(params, "selector")
            let script: String
            if let selector {
                let selectorLiteral = v2JSONLiteral(selector)
                script = """
                (() => {
                  const el = document.querySelector(\(selectorLiteral));
                  if (!el) return { ok: false, error: 'not_found' };
                  return { ok: true, value: String(el.innerText || el.textContent || '') };
                })()
                """
            } else {
                script = """
                (() => ({ ok: true, value: String((document.body && (document.body.innerText || document.body.textContent)) || (document.documentElement && document.documentElement.textContent) || '') }))()
                """
            }
            switch v2RunJavaScript(browserWebView, script: script, timeout: 5.0, world: .page) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .timedOut:
                return .err(code: "timeout", message: "Timed out reading browser text", data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "not_found", message: "Element not found", data: ["selector": selector ?? ""])
                }
                text = dict["value"] as? String ?? ""
                source = selector == nil ? "browser_document" : "browser_selector"
            }
        } else if let markdownPanel = ctx.markdownPanel {
            text = v2MainSync { markdownPanel.textContent.isEmpty ? markdownPanel.content : markdownPanel.textContent }
            source = "markdown_source"
        } else if let filePreviewPanel = ctx.filePreviewPanel {
            text = v2MainSync {
                if !filePreviewPanel.textContent.isEmpty {
                    return filePreviewPanel.textContent
                }
                return Self.readUTF8ishFile(path: filePreviewPanel.filePath) ?? ""
            }
            source = "file_preview_source"
        } else {
            return .err(
                code: "not_supported",
                message: "Surface type does not support text ingest yet",
                data: ["surface_id": ctx.surfaceId.uuidString, "surface_type": ctx.surfaceType]
            )
        }

        let limited = lineLimit.map { Self.tailTerminalLines(text, maxLines: $0) } ?? text
        var result = v2SurfaceBasePayload(ctx)
        result["text"] = limited
        result["base64"] = limited.data(using: .utf8)?.base64EncodedString() ?? ""
        result["source"] = source
        result["scrollback"] = ctx.terminalPanel != nil && (includeScrollback || lineLimit != nil)
        return .ok(result)
    }

    private nonisolated func v2MaterializeSurfaceAudit(
        payload: [String: Any],
        image: V2EncodedSurfaceImage?,
        text: String?,
        textSource: String?,
        reason: String
    ) -> [String: Any]? {
        let now = Date()
        let captureId = "capture-\(Int(now.timeIntervalSince1970 * 1000))-\(String(UUID().uuidString.prefix(8)).lowercased())"
        var directoryURL = Self.conductorAuditRootURL()
        for component in Self.auditDatePathComponents(now) {
            directoryURL.appendPathComponent(component, isDirectory: true)
        }
        directoryURL.appendPathComponent(captureId, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        var manifest = payload
        manifest.removeValue(forKey: "png_base64")
        manifest.removeValue(forKey: "jpeg_base64")
        manifest["capture_id"] = captureId
        manifest["captured_at"] = Self.iso8601String(now)
        manifest["reason"] = reason

        if let image {
            let imageURL = directoryURL.appendingPathComponent("screenshot.\(image.format.fileExtension)", isDirectory: false)
            if (try? image.data.write(to: imageURL, options: .atomic)) != nil {
                manifest["image_path"] = imageURL.path
                manifest["image_url"] = imageURL.absoluteString
                manifest["image_format"] = image.format.rawValue
                manifest["image_mime_type"] = image.format.mimeType
                manifest["image_file_extension"] = image.format.fileExtension
                manifest["image_byte_count"] = image.data.count
                manifest["image_width"] = image.width
                manifest["image_height"] = image.height
                manifest["image_original_width"] = image.originalWidth
                manifest["image_original_height"] = image.originalHeight
                manifest["image_aspect_ratio"] = image.aspectRatio
                manifest["image_profile"] = image.profile
                if let maxDimension = image.maxDimension {
                    manifest["image_max_dimension"] = maxDimension
                }
                if let jpegQuality = image.jpegQuality {
                    manifest["image_jpeg_quality"] = jpegQuality
                }
            }
        }

        if let text, !text.isEmpty {
            let textURL = directoryURL.appendingPathComponent("text.txt", isDirectory: false)
            if let data = text.data(using: .utf8),
               (try? data.write(to: textURL, options: .atomic)) != nil {
                manifest["text_path"] = textURL.path
                manifest["text_url"] = textURL.absoluteString
                manifest["text_source"] = textSource ?? "unknown"
                manifest["text_char_count"] = text.count
                if var textMetadata = manifest["text"] as? [String: Any] {
                    textMetadata["path"] = textURL.path
                    textMetadata["url"] = textURL.absoluteString
                    if let textSource {
                        textMetadata["source"] = textSource
                    } else if textMetadata["source"] == nil {
                        textMetadata["source"] = "unknown"
                    }
                    textMetadata["character_count"] = text.count
                    manifest["text"] = textMetadata
                }
            }
        }

        let manifestURL = directoryURL.appendingPathComponent("manifest.json", isDirectory: false)
        if let manifestData = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            try? manifestData.write(to: manifestURL, options: .atomic)
            manifest["manifest_path"] = manifestURL.path
            manifest["manifest_url"] = manifestURL.absoluteString
        }

        let indexURL = directoryURL.deletingLastPathComponent().appendingPathComponent("index.jsonl", isDirectory: false)
        if let lineData = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]) {
            if FileManager.default.fileExists(atPath: indexURL.path),
                let handle = try? FileHandle(forWritingTo: indexURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                handle.write(lineData)
                handle.write(Data([0x0A]))
            } else {
                var data = lineData
                data.append(0x0A)
                try? data.write(to: indexURL, options: .atomic)
            }
        }

        return manifest
    }

    private nonisolated func v2SurfaceIngestPromptBlock(
        surfacePayload: [String: Any],
        screenshotPayload: [String: Any]?,
        textPayload: [String: Any]?
    ) -> String {
        let surfaceRef = surfacePayload["surface_ref"] as? String ?? surfacePayload["surface_id"] as? String ?? "unknown"
        let surfaceType = surfacePayload["surface_type"] as? String ?? "unknown"
        var lines: [String] = []
        lines.append("cmux surface ingest")
        lines.append("surface: \(surfaceRef) (\(surfaceType))")
        if let title = surfacePayload["title"] as? String, !title.isEmpty {
            lines.append("title: \(title)")
        }
        if let screenshotPayload {
            let format = screenshotPayload["format"] as? String ?? "png"
            let width = screenshotPayload["width"] as? Int ?? 0
            let height = screenshotPayload["height"] as? Int ?? 0
            let ratio = screenshotPayload["aspect_ratio"] as? Double ?? 0
            let bytes = screenshotPayload["byte_count"] as? Int ?? 0
            lines.append("image: \(format), \(width)x\(height) px, aspect_ratio=\(String(format: "%.4f", ratio)), bytes=\(bytes)")
            if let imagePath = screenshotPayload["path"] as? String {
                lines.append("image_path: \(imagePath)")
            }
        }
        if let textPayload {
            let source = textPayload["source"] as? String ?? "unknown"
            let text = textPayload["text"] as? String ?? ""
            lines.append("text: \(text.count) chars from \(source)")
            if let textPath = textPayload["text_path"] as? String {
                lines.append("text_path: \(textPath)")
            }
        }
        if screenshotPayload != nil {
            lines.append("Use extracted text first. Use the image for layout, visual state, and OCR only where text extraction is incomplete.")
        } else {
            lines.append("Use extracted text as the surface snapshot. No image was captured for this ingest.")
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated func v2SurfacePanelContext(params: [String: Any]) -> (context: V2SurfacePanelContext?, error: V2CallResult?) {
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return (nil, .err(code: "unavailable", message: "TabManager not available", data: nil))
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return (nil, .err(code: "not_found", message: "Workspace not found", data: nil))
            }
            let resolvedSurface = v2ResolveAnySurfaceId(params: params, workspace: ws)
            if let error = resolvedSurface.error {
                return (nil, error)
            }
            guard let surfaceId = resolvedSurface.surfaceId else {
                return (nil, .err(code: "not_found", message: "No focused surface", data: nil))
            }
            guard let panel = ws.panels[surfaceId] else {
                return (nil, .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString]))
            }
            return (
                V2SurfacePanelContext(
                    windowId: v2ResolveWindowId(tabManager: tabManager),
                    workspaceId: ws.id,
                    surfaceId: surfaceId,
                    surfaceType: panel.panelType.rawValue,
                    title: panel.displayTitle,
                    terminalPanel: panel as? TerminalPanel,
                    browserPanel: panel as? BrowserPanel,
                    browserWebView: (panel as? BrowserPanel)?.webView,
                    markdownPanel: panel as? MarkdownPanel,
                    filePreviewPanel: panel as? FilePreviewPanel
                ),
                nil
            )
        }
    }

    private nonisolated func v2EncodedSurfaceImage(from payload: [String: Any]) -> V2EncodedSurfaceImage? {
        let formatRaw = (payload["format"] as? String)?.lowercased() ?? "png"
        let format: V2SurfaceImageFormat
        switch formatRaw {
        case "png":
            format = .png
        case "jpg", "jpeg":
            format = .jpeg
        default:
            return nil
        }
        let base64 = payload[format.base64Key] as? String
            ?? payload["png_base64"] as? String
            ?? payload["jpeg_base64"] as? String
        guard let base64,
              let data = Data(base64Encoded: base64),
              let width = payload["width"] as? Int,
              let height = payload["height"] as? Int else {
            return nil
        }
        return V2EncodedSurfaceImage(
            data: data,
            format: format,
            width: width,
            height: height,
            originalWidth: payload["original_width"] as? Int ?? width,
            originalHeight: payload["original_height"] as? Int ?? height,
            jpegQuality: payload["jpeg_quality"] as? Double,
            maxDimension: payload["max_dimension"] as? Int,
            profile: payload["profile"] as? String ?? "unknown"
        )
    }

    private func v2ResolveAnySurfaceId(
        params: [String: Any],
        workspace: Workspace
    ) -> (surfaceId: UUID?, error: V2CallResult?) {
        if let surfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id") {
            return (surfaceId, nil)
        }
        if let paneId = v2UUID(params, "pane_id") {
            guard let pane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == paneId }) else {
                return (
                    nil,
                    .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneId.uuidString])
                )
            }
            guard let selectedTab = workspace.bonsplitController.selectedTab(inPane: pane),
                  let selectedSurface = workspace.panelIdFromSurfaceId(selectedTab.id) else {
                return (
                    nil,
                    .err(code: "not_found", message: "Pane has no selected surface", data: ["pane_id": paneId.uuidString])
                )
            }
            return (selectedSurface, nil)
        }
        return (workspace.focusedPanelId, nil)
    }

    private nonisolated func v2SurfaceBasePayload(_ ctx: V2SurfacePanelContext) -> [String: Any] {
        [
            "workspace_id": ctx.workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: ctx.workspaceId),
            "surface_id": ctx.surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: ctx.surfaceId),
            "surface_type": ctx.surfaceType,
            "title": ctx.title,
            "window_id": v2OrNull(ctx.windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: ctx.windowId)
        ]
    }

    private nonisolated func v2SurfaceBasePayloadFromPayload(_ payload: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in ["workspace_id", "workspace_ref", "surface_id", "surface_ref", "surface_type", "title", "window_id", "window_ref"] {
            if let value = payload[key] {
                result[key] = value
            }
        }
        return result
    }
}
