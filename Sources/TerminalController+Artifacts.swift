import AppKit
import Bonsplit
import Foundation

// MARK: - Artifact socket commands

// Fork (cmux Mochi): `artifact.new`, `artifact.open`, and `artifact.list`.
// ControlCommandExecutionPolicy registered artifact.open/artifact.list, but the
// rebase dropped the Artifacts panel and these handlers with it, so both
// answered method_not_found.

extension TerminalController {

    func v2ArtifactOpen(params: [String: Any]) -> V2CallResult {
        let target = v2String(params, "target")
            ?? v2String(params, "id")
            ?? v2String(params, "path")
        guard let target else {
            return .err(code: "invalid_params", message: "artifact.open requires target, id, or path", data: nil)
        }

        let explicitKindRaw = v2String(params, "kind")?.lowercased()
        let explicitKind: ArtifactKind?
        if let explicitKindRaw {
            guard let parsedKind = ArtifactKind(rawValue: explicitKindRaw) else {
                return .err(code: "invalid_params", message: "Unsupported artifact kind: \(explicitKindRaw)", data: nil)
            }
            explicitKind = parsedKind
        } else {
            explicitKind = nil
        }
        let store = ArtifactStore()
        guard let resolved = store.resolve(identifier: target, explicitKind: explicitKind) else {
            return .err(code: "not_found", message: "Artifact not found or unsupported kind: \(target)", data: nil)
        }
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return .err(code: "not_found", message: "Artifact file does not exist: \(resolved.path)", data: nil)
        }

        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let directionStr = v2String(params, "direction")
        var result: V2CallResult = .err(code: "internal_error", message: "Failed to open artifact", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            let sourceSurfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let sourceSurfaceId, ws.panels[sourceSurfaceId] != nil else {
                result = .err(code: "not_found", message: "No source surface to open beside", data: nil)
                return
            }
            guard let sourcePane = ws.paneId(forPanelId: sourceSurfaceId) else {
                result = .err(code: "not_found", message: "Source pane not found", data: nil)
                return
            }

            let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)
            let split: (orientation: SplitOrientation, insertFirst: Bool)
            if let directionStr, let direction = parseSplitDirection(directionStr) {
                split = (direction.isHorizontal ? .horizontal : .vertical,
                         direction == .left || direction == .up)
            } else {
                split = (.horizontal, false)
            }

            let panel: ArtifactPanel?
            if directionStr == nil,
               let targetPane = ws.preferredRightSideTargetPane(fromPanelId: sourceSurfaceId) {
                panel = ws.openOrFocusArtifactSurface(
                    inPane: targetPane,
                    filePath: resolved.path,
                    kind: resolved.kind,
                    focus: focus
                )
            } else {
                panel = ws.splitPaneWithArtifact(
                    targetPane: sourcePane,
                    orientation: split.orientation,
                    insertFirst: split.insertFirst,
                    filePath: resolved.path,
                    kind: resolved.kind,
                    focus: focus
                )
            }

            guard let panel else {
                result = .err(code: "internal_error", message: "Failed to open artifact", data: nil)
                return
            }

            let targetPaneUUID = ws.paneId(forPanelId: panel.id)?.id
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            var payload: [String: Any] = [
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": panel.id.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
                "pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "file_path": panel.filePath,
                "kind": panel.kind.rawValue
            ]
            if let record = resolved.record {
                payload["artifact"] = v2ArtifactRecordPayload(record, store: store)
            }
            result = .ok(payload)
        }
        return result
    }

    func v2ArtifactList(params: [String: Any]) -> V2CallResult {
        let limit = v2Int(params, "limit")
        if let limit, limit < 0 {
            return .err(code: "invalid_params", message: "limit must be >= 0", data: nil)
        }

        let store = ArtifactStore()
        let repoRaw = v2String(params, "repo") ?? v2String(params, "repo_root")
        let repoRoot = repoRaw.map { raw in
                let expanded = (raw as NSString).expandingTildeInPath
                return ArtifactStore.gitRepoRoot(for: expanded) ?? ArtifactStore.normalizedPath(expanded)
            }
        let records = store.listRecords(repoRoot: repoRoot, limit: limit)
        return .ok([
            "root_path": store.rootPath,
            "count": records.count,
            "records": records.map { v2ArtifactRecordPayload($0, store: store) }
        ])
    }

    private func v2ArtifactNew(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let title = v2String(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kindRaw = v2String(params, "kind")?.lowercased()
        var kind: ArtifactKind = .react
        if let kindRaw {
            guard let parsedKind = ArtifactKind(rawValue: kindRaw) else {
                return .err(code: "invalid_params", message: "Unsupported artifact kind: \(kindRaw)", data: nil)
            }
            kind = parsedKind
        }
        let directionStr = v2String(params, "direction")

        // Optional bundled sample/template (e.g. "showcase"). Its content + kind +
        // title override the scaffold defaults when no explicit ones are given.
        var sampleSource: String?
        var sampleTitle: String?
        if let templateName = v2String(params, "template")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !templateName.isEmpty {
            guard let sample = ArtifactSamples.sample(named: templateName),
                  let source = ArtifactSamples.source(for: sample) else {
                return .err(code: "not_found", message: "Unknown artifact template: \(templateName)", data: nil)
            }
            sampleSource = source
            sampleTitle = sample.title
            if kindRaw == nil { kind = sample.kind }
        }

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create artifact", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)

            let sourceSurfaceId = v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let sourceSurfaceId, ws.panels[sourceSurfaceId] != nil else {
                result = .err(code: "not_found", message: "No source surface to open beside", data: nil)
                return
            }
            guard let sourcePane = ws.paneId(forPanelId: sourceSurfaceId) else {
                result = .err(code: "not_found", message: "Source pane not found", data: nil)
                return
            }

            let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)
            let originCwd = ws.panelDirectories[sourceSurfaceId]
            let resolvedTitle = (title?.isEmpty == false) ? title! : (sampleTitle ?? "Artifact")

            // direction → split placement; default to a right-hand split.
            let split: (orientation: SplitOrientation, insertFirst: Bool)
            if let directionStr, let direction = parseSplitDirection(directionStr) {
                split = (direction.isHorizontal ? .horizontal : .vertical,
                         direction == .left || direction == .up)
            } else {
                split = (.horizontal, false)
            }

            guard let panel = ws.createArtifact(
                title: resolvedTitle,
                kind: kind,
                inPane: sourcePane,
                split: split,
                originCwd: originCwd,
                originSurfaceId: sourceSurfaceId.uuidString,
                source: sampleSource,
                focus: focus
            ) else {
                result = .err(code: "internal_error", message: "Failed to create artifact", data: nil)
                return
            }

            let targetPaneUUID = ws.paneId(forPanelId: panel.id)?.id
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": panel.id.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
                "pane_id": v2OrNull(targetPaneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: targetPaneUUID),
                "file_path": panel.filePath,
                "kind": panel.kind.rawValue
            ])
        }
        return result
    }

    private func v2ArtifactRecordPayload(_ record: ArtifactRecord, store: ArtifactStore) -> [String: Any] {
        [
            "id": record.id,
            "created_at": record.createdAt,
            "title": record.title,
            "kind": record.kind.rawValue,
            "relative_path": record.file,
            "file_path": store.absolutePath(for: record),
            "file_exists": FileManager.default.fileExists(atPath: store.absolutePath(for: record)),
            "origin": [
                "cwd": v2OrNull(record.origin.cwd),
                "repo_root": v2OrNull(record.origin.repoRoot),
                "workspace_id": v2OrNull(record.origin.workspaceId),
                "surface_id": v2OrNull(record.origin.surfaceId)
            ]
        ]
    }
}
