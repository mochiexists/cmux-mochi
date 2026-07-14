import AppKit
import CmuxControlSocket
import CmuxFoundation
import Foundation
import WebKit

@MainActor
final class ArtifactRuntimeCmuxBridge {
    static let roomCapabilityMarker = #"<meta name="cmux-artifact-room" content="enabled">"#

    private struct LiveSubscription {
        let subscription: CmuxEventSubscription
        let task: Task<Void, Never>
        let scope: String
    }

    private weak var webView: WKWebView?
    private var panelId: UUID = UUID()
    private var workspaceId: UUID = UUID()
    private var filePath: String = ""
    private var subscriptions: [String: LiveSubscription] = [:]
    private var roomEnabled = false
    private var roomWatcher: FileWatcher?
    private var roomWatchTask: Task<Void, Never>?
    #if DEBUG
    var dispatchSinkForTesting: ((String, [String: Any]) -> Void)?
    #endif

    func update(
        panelId: UUID,
        workspaceId: UUID,
        filePath: String,
        webView: WKWebView?,
        roomEnabled: Bool = false
    ) {
        if filePath != self.filePath {
            stopRoomWatcher()
        }
        self.panelId = panelId
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.webView = webView
        setRoomEnabled(roomEnabled)
    }

    func updateRoomCapability(from source: String) {
        setRoomEnabled(source.contains(Self.roomCapabilityMarker))
    }

    func close() {
        for live in subscriptions.values {
            live.task.cancel()
            CmuxEventBus.shared.unsubscribe(live.subscription)
        }
        subscriptions.removeAll()
        stopRoomWatcher()
        roomEnabled = false
        webView = nil
    }

    func handle(message: Any) -> [String: Any] {
        guard let request = message as? [String: Any] else {
            return failure(requestId: nil, error: "invalid cmux bridge request")
        }
        return handle(request: request)
    }

    func handle(request: [String: Any]) -> [String: Any] {
        let requestId = stringValue(request["requestId"])
        let op = stringValue(request["op"]) ?? ""
        let payload = request["payload"] as? [String: Any] ?? [:]

        switch op {
        case "call":
            let method = stringValue(payload["method"]) ?? stringValue(request["method"]) ?? ""
            let params = payload["params"] as? [String: Any] ?? [:]
            return callResponse(requestId: requestId, method: method, params: params)
        case "subscribe":
            let options = payload["options"] as? [String: Any] ?? payload
            return subscribeResponse(requestId: requestId, options: options)
        case "unsubscribe":
            let id = stringValue(payload["subscriptionId"]) ?? stringValue(payload["id"]) ?? stringValue(request["subscriptionId"])
            return unsubscribeResponse(requestId: requestId, subscriptionId: id)
        default:
            return failure(requestId: requestId, error: "unsupported cmux bridge operation '\(op)'")
        }
    }

    private func callResponse(requestId: String?, method: String, params: [String: Any]) -> [String: Any] {
        if method == "room.read" || method == "room.post" {
            guard roomEnabled else {
                return failure(
                    requestId: requestId,
                    error: "room capability is not enabled for this artifact"
                )
            }
        }
        let value: Any
        switch method {
        case "capabilities":
            value = capabilities()
        case "snapshot", "system.snapshot":
            value = systemSnapshot(scope: scope(from: params))
        case "events.snapshot":
            value = [
                "latest_seq": NSNumber(value: CmuxEventBus.shared.latestSequence),
                "events": filteredEvents(
                    CmuxEventBus.shared.retainedSnapshot(),
                    scope: scope(from: params),
                    limit: intValue(params["limit"]) ?? 100
                )
            ]
        case "surface.read", "readSurface":
            value = readSurface(params: params)
        case "context", "artifact.context":
            value = contextSnapshot()
        case "room.read":
            value = roomRead()
        case "room.post":
            value = roomPost(params: params)
        default:
            return failure(requestId: requestId, error: "unsupported cmux bridge method '\(method)'")
        }

        return success(requestId: requestId, value: value)
    }

    private func subscribeResponse(requestId: String?, options: [String: Any]) -> [String: Any] {
        let afterSequence = int64Value(options["afterSeq"] ?? options["after_seq"])
        let names = stringSet(options["names"])
        let categories = stringSet(options["categories"])
        let scope = scope(from: options)
        let limit = intValue(options["replayLimit"] ?? options["replay_limit"]) ?? 100
        let snapshot = CmuxEventBus.shared.subscribe(afterSequence: afterSequence, names: names, categories: categories)
        let subscriptionId = snapshot.subscription.id.uuidString
        let replay = filteredEvents(snapshot.replay, scope: scope, limit: limit)

        let task = Task.detached { [subscription = snapshot.subscription, scope] in
            while !Task.isCancelled {
                if let event = subscription.next(timeout: CmuxEventBus.defaultHeartbeatIntervalSeconds) {
                    await MainActor.run {
                        self.dispatch(subscriptionId: subscriptionId, event: event, scope: scope)
                    }
                    continue
                }
                if subscription.isClosed {
                    break
                }
                let heartbeat = CmuxEventBus.shared.heartbeat(subscription: subscription)
                await MainActor.run {
                    self.dispatch(subscriptionId: subscriptionId, event: heartbeat, scope: scope)
                }
            }
        }
        subscriptions[subscriptionId] = LiveSubscription(subscription: snapshot.subscription, task: task, scope: scope)

        var ack = snapshot.ack
        ack["replay_count"] = replay.count

        return success(requestId: requestId, value: [
            "subscription_id": subscriptionId,
            "ack": ack,
            "replay": replay
        ])
    }

    private func unsubscribeResponse(requestId: String?, subscriptionId: String?) -> [String: Any] {
        guard let subscriptionId,
              let live = subscriptions.removeValue(forKey: subscriptionId) else {
            return success(requestId: requestId, value: ["unsubscribed": false])
        }
        live.task.cancel()
        CmuxEventBus.shared.unsubscribe(live.subscription)
        return success(requestId: requestId, value: ["unsubscribed": true])
    }

    private func dispatch(subscriptionId: String, event: [String: Any], scope: String) {
        guard eventIsVisible(event, scope: scope) else { return }
        #if DEBUG
        dispatchSinkForTesting?(subscriptionId, event)
        #endif
        guard let webView else { return }
        let payload: [String: Any] = [
            "subscriptionId": subscriptionId,
            "event": event
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: CmuxEventBus.sanitizedJSONValue(payload)),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__cmuxArtifactCmuxDispatch && window.__cmuxArtifactCmuxDispatch(\(json));")
    }

    private func systemSnapshot(scope: String) -> [String: Any] {
        return [
            "protocol": "cmux-artifact-bridge",
            "protocol_version": 2,
            "schema_version": 1,
            "generated_at": CmuxEventBus.isoTimestamp(Date()),
            "artifact": [
                "panel_id": panelId.uuidString,
                "workspace_id": workspaceId.uuidString,
                "file_path": filePath
            ],
            "event": [
                "latest_seq": NSNumber(value: CmuxEventBus.shared.latestSequence)
            ],
            "scope": [
                "mode": scope,
                "workspace_id": workspaceId.uuidString
            ],
            "windows": windowSnapshots(scope: scope),
            "v3_plan": [
                "Native SwiftUI workbench surface with the same bridge contract.",
                "Dedicated log drawers for event bus, control socket commands, and artifact runtime calls.",
                "Timeline replay with persisted event log backfill and per-surface text previews.",
                "Promotion path from prototype artifact to first-party cmux debugging module."
            ]
        ]
    }

    private func capabilities() -> [String: Any] {
        var methods = [
            "capabilities", "snapshot", "system.snapshot", "events.snapshot",
            "surface.read", "readSurface", "context"
        ]
        if roomEnabled {
            methods.append(contentsOf: ["room.read", "room.post"])
        }
        return [
            "protocol": "cmux-artifact-bridge",
            "protocol_version": 2,
            "read_only": !roomEnabled,
            "methods": methods,
            "writes": roomEnabled ? ["room.post"] : [],
            "subscriptions": [
                "event_bus": true,
                "filters": ["names", "categories", "afterSeq", "scope", "replayLimit"]
            ]
        ]
    }

    // MARK: - Self context

    /// Resolves where this artifact currently lives in the UI — window,
    /// workspace, pane, and surface (id + `kind:N` socket ref + indexes). The
    /// lookup scans live topology by the artifact's panel id, so it stays
    /// correct after the surface is dragged to another pane, workspace, or
    /// window.
    private func contextSnapshot() -> [String: Any] {
        guard let app = AppDelegate.shared else {
            return ["ok": false, "code": "unavailable", "message": "App context is not available"]
        }
        for summary in app.listMainWindowSummaries() {
            guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }
            for (workspaceIndex, workspace) in manager.tabs.enumerated() {
                guard workspace.panels[panelId] != nil,
                      let pane = workspace.paneId(forPanelId: panelId) else { continue }
                let tabIds = workspace.surfaceIdsInTabOrder(inPaneId: pane.id)
                let selectedTabId = workspace.selectedSurfaceId(inPaneId: pane.id)
                let ownTabIndex = workspace.indexInPane(forPanelId: panelId)
                let ownTabId: UUID? = ownTabIndex.flatMap { index in
                    tabIds.indices.contains(index) ? tabIds[index] : nil
                }
                let paneIndex = workspace.allPaneIds.firstIndex(where: { $0 == pane.id })
                return [
                    "ok": true,
                    "generated_at": CmuxEventBus.isoTimestamp(Date()),
                    "file_path": filePath,
                    "window": [
                        "id": summary.windowId.uuidString,
                        "ref": socketRef(kind: .window, uuid: summary.windowId),
                        "is_key": summary.isKeyWindow
                    ],
                    "workspace": [
                        "id": workspace.id.uuidString,
                        "ref": socketRef(kind: .workspace, uuid: workspace.id),
                        "index": workspaceIndex,
                        "title": workspace.title,
                        "is_selected": workspace.id == summary.selectedWorkspaceId
                    ],
                    "pane": [
                        "id": pane.id.uuidString,
                        "ref": socketRef(kind: .pane, uuid: pane.id),
                        "index": paneIndex ?? NSNull(),
                        "tab_count": tabIds.count
                    ],
                    "surface": [
                        "id": panelId.uuidString,
                        "ref": socketRef(kind: .surface, uuid: panelId),
                        "title": workspace.panelTitle(panelId: panelId)
                            ?? workspace.panels[panelId]?.displayTitle
                            ?? "",
                        "tab_index": ownTabIndex ?? NSNull(),
                        "is_selected": ownTabId != nil && ownTabId == selectedTabId,
                        "is_focused": workspace.focusedPanelId == panelId
                    ]
                ]
            }
        }
        return ["ok": false, "code": "not_found", "message": "Artifact surface is not attached to any workspace"]
    }

    /// Mints the same `kind:N` handle the cmux socket CLI reports, so text an
    /// artifact renders matches `cmux tree` / `cmux identify` output.
    private func socketRef(kind: ControlHandleKind, uuid: UUID) -> Any {
        TerminalController.shared.v2Ref(kind: kind, uuid: uuid)
    }

    // MARK: - Room (multi-agent scratchpad sidecar)

    /// `room.read` — parse the artifact's `.room.jsonl` sidecar. Starts the
    /// sidecar watcher so external appends (agents posting from a shell)
    /// re-notify the artifact.
    private func roomRead() -> [String: Any] {
        let store = ArtifactRoomStore(artifactFilePath: filePath)
        ensureRoomWatcher()
        let result = store.read()
        return [
            "ok": true,
            "path": store.roomPath,
            "exists": result.exists,
            "entries": result.entries,
            "skipped": result.skipped,
            "truncated": result.truncated
        ]
    }

    /// `room.post` — validate and append one entry to the sidecar (the
    /// artifact compose box path). The watcher then fans the change back out
    /// to the artifact, same as an external append.
    private func roomPost(params: [String: Any]) -> [String: Any] {
        let store = ArtifactRoomStore(artifactFilePath: filePath)
        ensureRoomWatcher()
        do {
            let entry = try store.append(entry: params)
            return ["ok": true, "path": store.roomPath, "entry": entry]
        } catch {
            return ["ok": false, "code": "invalid_params", "message": error.localizedDescription]
        }
    }

    /// Watches the room sidecar (created lazily on first room call; the
    /// watcher recovers via nearest-existing-ancestor when the file does not
    /// exist yet) and pings the shell so room UIs re-read on every append.
    private func ensureRoomWatcher() {
        guard roomWatchTask == nil else { return }
        let store = ArtifactRoomStore(artifactFilePath: filePath)
        let watcher = FileWatcher(path: store.roomPath)
        roomWatcher = watcher
        let events = watcher.events
        roomWatchTask = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self else { break }
                self.webView?.evaluateJavaScript(
                    "window.__cmuxArtifactRoomDispatch && window.__cmuxArtifactRoomDispatch();",
                    completionHandler: nil
                )
            }
        }
    }

    private func stopRoomWatcher() {
        roomWatchTask?.cancel()
        roomWatchTask = nil
        roomWatcher = nil
    }

    private func setRoomEnabled(_ enabled: Bool) {
        if roomEnabled, !enabled {
            stopRoomWatcher()
        }
        roomEnabled = enabled
    }

    private func windowSnapshots(scope: String) -> [[String: Any]] {
        guard let app = AppDelegate.shared else { return [] }
        return app.listMainWindowSummaries().compactMap { summary in
            guard let manager = app.tabManagerFor(windowId: summary.windowId) else { return nil }
            let workspaces = manager.tabs.enumerated().compactMap { index, workspace -> [String: Any]? in
                guard scope == "all" || workspace.id == workspaceId else { return nil }
                return workspaceSnapshot(workspace: workspace, index: index, selectedWorkspaceId: summary.selectedWorkspaceId)
            }
            guard !workspaces.isEmpty || scope == "all" else { return nil }
            return [
                "id": summary.windowId.uuidString,
                "is_key": summary.isKeyWindow,
                "is_visible": summary.isVisible,
                "workspace_count": summary.workspaceCount,
                "selected_workspace_id": summary.selectedWorkspaceId?.uuidString ?? NSNull(),
                "workspaces": workspaces
            ]
        }
    }

    private func workspaceSnapshot(workspace: Workspace, index: Int, selectedWorkspaceId: UUID?) -> [String: Any] {
        let paneIds = workspace.allPaneIds
        return [
            "id": workspace.id.uuidString,
            "index": index,
            "title": workspace.title,
            "description": workspace.customDescription ?? NSNull(),
            "is_selected": workspace.id == selectedWorkspaceId,
            "focused_surface_id": workspace.focusedPanelId?.uuidString ?? NSNull(),
            "panes": paneIds.enumerated().map { paneIndex, paneId in
                paneSnapshot(workspace: workspace, paneId: paneId, index: paneIndex)
            }
        ]
    }

    private func paneSnapshot(workspace: Workspace, paneId: UUID, index: Int) -> [String: Any] {
        let selectedSurfaceId = workspace.selectedSurfaceId(inPaneId: paneId)
        let surfaceIds = workspace.surfaceIdsInTabOrder(inPaneId: paneId)
        return [
            "id": paneId.uuidString,
            "index": index,
            "is_focused": workspace.bonsplitController.focusedPaneId?.id == paneId,
            "selected_surface_id": selectedSurfaceId?.uuidString ?? NSNull(),
            "surfaces": surfaceIds.enumerated().compactMap { surfaceIndex, surfaceId in
                surfaceSnapshot(workspace: workspace, surfaceId: surfaceId, index: surfaceIndex, selectedSurfaceId: selectedSurfaceId)
            }
        ]
    }

    private func surfaceSnapshot(
        workspace: Workspace,
        surfaceId: UUID,
        index: Int,
        selectedSurfaceId: UUID?
    ) -> [String: Any]? {
        guard let panelId = workspace.panelId(forSurfaceId: surfaceId),
              let panel = workspace.panels[panelId] else { return nil }
        var snapshot: [String: Any] = [
            "id": panel.id.uuidString,
            "surface_id": surfaceId.uuidString,
            "index": index,
            "type": panel.panelType.rawValue,
            "title": workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle,
            "is_selected": surfaceId == selectedSurfaceId,
            "is_focused": panel.id == workspace.focusedPanelId,
            "tty": workspace.surfaceTTYNames[panel.id] ?? NSNull()
        ]
        if let browser = panel as? BrowserPanel {
            snapshot["url"] = browser.currentURL?.absoluteString ?? NSNull()
        }
        return snapshot
    }

    private func readSurface(params: [String: Any]) -> [String: Any] {
        let requestedId = stringValue(params["surfaceId"])
            ?? stringValue(params["surface_id"])
            ?? stringValue(params["id"])
        guard let resolved = resolveSurface(requestedId: requestedId) else {
            return [
                "ok": false,
                "code": "not_found",
                "message": "Surface is not visible to this artifact bridge"
            ]
        }

        var payload = surfaceSnapshot(
            workspace: resolved.workspace,
            surfaceId: resolved.surfaceId,
            index: resolved.index,
            selectedSurfaceId: resolved.selectedSurfaceId
        ) ?? [
            "id": resolved.panel.id.uuidString,
            "surface_id": resolved.surfaceId.uuidString,
            "type": resolved.panel.panelType.rawValue,
            "title": resolved.workspace.panelTitle(panelId: resolved.panel.id) ?? resolved.panel.displayTitle
        ]
        payload["ok"] = true

        if let artifactPanel = resolved.panel as? ArtifactPanel {
            payload["text"] = artifactPanel.source
            payload["source"] = "artifact_source"
        } else if let markdownPanel = resolved.panel as? MarkdownPanel {
            payload["text"] = markdownPanel.textContent.isEmpty ? markdownPanel.content : markdownPanel.textContent
            payload["source"] = "markdown_source"
            payload["file_path"] = markdownPanel.filePath
        } else if let filePreviewPanel = resolved.panel as? FilePreviewPanel {
            payload["text"] = !filePreviewPanel.textContent.isEmpty
                ? filePreviewPanel.textContent
                : (Self.readUTF8ishFile(path: filePreviewPanel.filePath) ?? "")
            payload["source"] = "file_preview_source"
            payload["file_path"] = filePreviewPanel.filePath
        } else {
            payload["ok"] = false
            payload["code"] = "not_supported"
            payload["message"] = "This bridge currently exposes metadata for this surface type; use the cmux socket surface.text/ingest path for full text capture."
        }

        if let text = payload["text"] as? String {
            payload["text_char_count"] = text.count
        }
        return payload
    }

    private struct ResolvedSurface {
        let workspace: Workspace
        let surfaceId: UUID
        let panel: any Panel
        let index: Int
        let selectedSurfaceId: UUID?
    }

    private func resolveSurface(requestedId: String?) -> ResolvedSurface? {
        guard let app = AppDelegate.shared else { return nil }
        let visibleWorkspaces = app.listMainWindowSummaries().compactMap { summary -> [Workspace]? in
            guard let manager = app.tabManagerFor(windowId: summary.windowId) else { return nil }
            return manager.tabs
        }.flatMap { $0 }

        let workspaces = visibleWorkspaces.filter { workspace in
            requestedId != nil || workspace.id == workspaceId
        }

        for workspace in workspaces {
            for paneId in workspace.allPaneIds {
                let selectedSurfaceId = workspace.selectedSurfaceId(inPaneId: paneId)
                let surfaceIds = workspace.surfaceIdsInTabOrder(inPaneId: paneId)
                for (index, surfaceId) in surfaceIds.enumerated() {
                    guard requestedId == nil ||
                        requestedId == surfaceId.uuidString ||
                        requestedId == workspace.panelId(forSurfaceId: surfaceId)?.uuidString else { continue }
                    guard let panelId = workspace.panelId(forSurfaceId: surfaceId),
                          let panel = workspace.panels[panelId] else { continue }
                    return ResolvedSurface(
                        workspace: workspace,
                        surfaceId: surfaceId,
                        panel: panel,
                        index: index,
                        selectedSurfaceId: selectedSurfaceId
                    )
                }
            }
        }
        return nil
    }

    private static func readUTF8ishFile(path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private func filteredEvents(_ events: [[String: Any]], scope: String, limit: Int) -> [[String: Any]] {
        let visible = events.filter { eventIsVisible($0, scope: scope) }
        guard limit > 0, visible.count > limit else { return visible }
        return Array(visible.suffix(limit))
    }

    private func eventIsVisible(_ event: [String: Any], scope: String) -> Bool {
        guard scope != "all" else { return true }
        guard let eventWorkspaceId = stringValue(event["workspace_id"]) else { return true }
        return eventWorkspaceId == workspaceId.uuidString
    }

    private func scope(from params: [String: Any]) -> String {
        stringValue(params["scope"]) == "all" ? "all" : "workspace"
    }

    private func success(requestId: String?, value: Any) -> [String: Any] {
        [
            "requestId": requestId ?? "",
            "ok": true,
            "value": CmuxEventBus.sanitizedJSONValue(value)
        ]
    }

    private func failure(requestId: String?, error: String) -> [String: Any] {
        [
            "requestId": requestId ?? "",
            "ok": false,
            "error": error
        ]
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        return nil
    }

    private func stringSet(_ value: Any?) -> Set<String> {
        if let strings = value as? [String] {
            return Set(strings.filter { !$0.isEmpty })
        }
        if let values = value as? [Any] {
            return Set(values.compactMap { stringValue($0) })
        }
        if let string = stringValue(value) {
            return [string]
        }
        return []
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func int64Value(_ value: Any?) -> Int64? {
        if let int64 = value as? Int64 { return int64 }
        if let int = value as? Int { return Int64(int) }
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }
}
