import AppKit
import Bonsplit
import CmuxControlSocket
import Darwin
import Foundation

/// The surface-domain input / read / resume / reporting witnesses, plus the
/// `surface.move` bridge and `debug.terminals` passthrough. Split out of
/// `TerminalController+ControlSurfaceContext` to keep the conformance readable; see
/// that file's doc comment for the overview.
extension TerminalController {

    // MARK: - move (bridge to still-app-side v2SurfaceMove)

    func controlSurfaceMove(params: [String: JSONValue]) -> ControlCallResult {
        // `v2SurfaceMove` walks windows/workspaces/panes and mutates Bonsplit; it
        // stays in TerminalController.swift (shared with pane.join). We forward the
        // raw params and bridge its Foundation result, exactly as pane.join does.
        let foundationParams = params.mapValues(\.foundationObject)
        switch v2SurfaceMove(params: foundationParams) {
        case let .ok(payload):
            return .ok(JSONValue(foundationObject: payload) ?? .object([:]))
        case let .err(code, message, data):
            return .err(code: code, message: message, data: data.flatMap { JSONValue(foundationObject: $0) })
        }
    }

    // MARK: - reorder

    func controlSurfaceReorder(
        surfaceID: UUID,
        inputs: ControlSurfaceReorderInputs,
        requestedFocus: Bool
    ) -> ControlSurfaceReorderResolution {
        let focus = v2FocusAllowed(requested: requestedFocus)
        guard let app = AppDelegate.shared,
              let located = app.locateSurface(surfaceId: surfaceID),
              let ws = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
              let sourcePane = ws.paneId(forPanelId: surfaceID) else {
            return .surfaceNotFound(surfaceID)
        }

        let targetIndex: Int
        if let index = inputs.index {
            targetIndex = index
        } else if let beforeSurfaceID = inputs.beforeSurfaceID {
            guard let anchorPane = ws.paneId(forPanelId: beforeSurfaceID),
                  anchorPane == sourcePane,
                  let anchorIndex = ws.indexInPane(forPanelId: beforeSurfaceID) else {
                return .anchorNotInSamePane
            }
            targetIndex = anchorIndex
        } else if let afterSurfaceID = inputs.afterSurfaceID {
            guard let anchorPane = ws.paneId(forPanelId: afterSurfaceID),
                  anchorPane == sourcePane,
                  let anchorIndex = ws.indexInPane(forPanelId: afterSurfaceID) else {
                return .anchorNotInSamePane
            }
            targetIndex = anchorIndex + 1
        } else {
            // Unreachable: the coordinator enforces exactly-one-target.
            return .reorderFailed
        }

        guard ws.reorderSurface(panelId: surfaceID, toIndex: targetIndex, focus: focus) else {
            return .reorderFailed
        }
        return .reordered(
            windowID: located.windowId,
            workspaceID: ws.id,
            paneID: sourcePane.id,
            surfaceID: surfaceID
        )
    }

    // MARK: - refresh

    func controlSurfaceRefresh(routing: ControlRoutingSelectors) -> ControlSurfaceRefreshResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        var refreshedCount = 0
        for panel in ws.panels.values {
            if let terminalPanel = panel as? TerminalPanel {
                terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceRefresh")
                refreshedCount += 1
            }
        }
        return .refreshed(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            refreshedCount: refreshedCount
        )
    }

    // MARK: - clear_history

    func controlSurfaceClearHistory(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool
    ) -> ControlSurfaceClearHistoryResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        // Legacy: a present-but-unparseable surface_id errors; it must never fall
        // back to clearing the focused surface (wrong-target side effect).
        if hasSurfaceIDParam, surfaceID == nil {
            return .surfaceNotFoundForID
        }
        guard let surfaceId = surfaceID ?? ws.focusedPanelId else {
            return .noFocusedSurface
        }
        guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
            return .surfaceNotTerminal(surfaceId)
        }
        guard terminalPanel.performBindingAction("clear_screen") else {
            return .bindingActionUnavailable
        }
        terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceClearHistory")
        return .cleared(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceId
        )
    }

    // MARK: - trigger_flash

    func controlSurfaceTriggerFlash(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlSurfaceTriggerFlashResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        guard let surfaceId = surfaceID ?? ws.focusedPanelId else {
            return .noFocusedSurface
        }
        guard ws.panels[surfaceId] != nil else {
            return .surfaceNotFound(surfaceId)
        }
        v2MaybeFocusWindow(for: tabManager)
        v2MaybeSelectWorkspace(tabManager, workspace: ws)
        ws.triggerFocusFlash(panelId: surfaceId)
        return .flashed(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceId
        )
    }

    // MARK: - send_text / send_key

    func controlSurfaceInputStrings() -> ControlSurfaceInputStrings {
        ControlSurfaceInputStrings(
            inputQueueFull: String(
                localized: "socket.terminal.inputQueueFull",
                defaultValue: "The terminal can't accept more input right now. Wait a moment and retry, or reopen the terminal if it stays unavailable."
            ),
            surfaceUnavailable: String(
                localized: "socket.terminal.surfaceUnavailable",
                defaultValue: "The terminal surface is no longer available; reopen it or create a new terminal session."
            ),
            processExited: String(
                localized: "socket.terminal.processExited",
                defaultValue: "The terminal session has ended; reopen it or create a new terminal session."
            ),
            liveForegroundJob: String(
                localized: "socket.terminal.liveForegroundJob",
                defaultValue: "The target pane has a live foreground job that would receive this text on its stdin. Send to a fresh pane, or pass force to send anyway."
            )
        )
    }

    /// Resolves the send target surface, matching the legacy
    /// `params["surface_id"] != nil` branch (an explicit param that did not parse
    /// signals `surfaceNotFoundForID`; otherwise the focused surface).
    /// The send-target resolution outcome (a domain value, not an `Error`, so it
    /// is not a `Result.Failure`).
    private enum SendSurfaceTarget {
        case surface(UUID)
        case unresolved(ControlSurfaceSendResolution)
    }

    private func resolveSendSurface(
        in ws: Workspace,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool
    ) -> SendSurfaceTarget {
        if hasSurfaceIDParam {
            guard let surfaceId = surfaceID else {
                return .unresolved(.surfaceNotFoundForID)
            }
            return .surface(surfaceId)
        }
        guard let focused = ws.focusedPanelId else {
            return .unresolved(.noFocusedSurface)
        }
        return .surface(focused)
    }

    func controlSurfaceSendText(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        text: String,
        force: Bool
    ) -> ControlSurfaceSendResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        let surfaceId: UUID
        switch resolveSendSurface(in: ws, surfaceID: surfaceID, hasSurfaceIDParam: hasSurfaceIDParam) {
        case .unresolved(let resolution): return resolution
        case .surface(let id): surfaceId = id
        }
        guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
            return .surfaceNotTerminal(surfaceId)
        }
        let sendGuardForegroundPID = terminalPanel.surface.foregroundProcessID()
        let sendGuardForegroundName = sendGuardForegroundPID.flatMap(Self.sendGuardProcessName(pid:))
        #if DEBUG
        cmuxDebugLog(
            "sendGuard surface=\(surfaceId.uuidString.prefix(5)) " +
            "state=\(ws.panelShellActivityStates[surfaceId]?.rawValue ?? "nil") " +
            "binding=\(ws.surfaceResumeBindingsByPanelId[surfaceId] != nil) " +
            "lifecycle=\(!(ws.agentLifecycleStatesByPanelId[surfaceId] ?? [:]).isEmpty) " +
            "fgPid=\(sendGuardForegroundPID.map(String.init) ?? "nil") " +
            "fgName=\(sendGuardForegroundName ?? "nil") force=\(force)"
        )
        #endif
        if ControlSurfaceSendGuard.blocksTextSend(
            isCommandRunning: ws.panelShellActivityStates[surfaceId] == .commandRunning,
            hasAgentEvidence: ws.surfaceResumeBindingsByPanelId[surfaceId] != nil
                || !(ws.agentLifecycleStatesByPanelId[surfaceId] ?? [:]).isEmpty,
            foregroundCommandName: sendGuardForegroundName,
            force: force
        ) {
            return .liveForegroundJob(surfaceId)
        }
        let queued: Bool
        switch terminalPanel.sendInputResult(text) {
        case .sent:
            terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceSendText")
            queued = false
        case .queued:
            queued = true
        case .inputQueueFull:
            return .inputQueueFull(surfaceId)
        case .surfaceUnavailable:
            return .surfaceUnavailable(surfaceId)
        case .processExited:
            return .processExited(surfaceId)
        }
        return .sent(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceId,
            queued: queued
        )
    }

    /// The foreground process's short name for the send guard's agent-CLI
    /// exemption, from `proc_pidinfo(PROC_PIDTBSDINFO).pbi_comm` — the same
    /// source `CmuxTopProcessEnumeration` uses (`proc_name` is unreliable from
    /// this process; the snapshot code only uses it as enrichment over
    /// `pbi_comm`). Returns `nil` when unresolvable — the guard's name
    /// exemption simply does not apply then.
    private static func sendGuardProcessName(pid: Int) -> String? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        guard size == expectedSize else { return nil }
        let name = withUnsafeBytes(of: info.pbi_comm) { raw in
            let end = raw.firstIndex(of: 0) ?? raw.endIndex
            return String(decoding: raw[..<end], as: UTF8.self)
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func controlSurfaceSendKey(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        key: String
    ) -> ControlSurfaceSendResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        let surfaceId: UUID
        switch resolveSendSurface(in: ws, surfaceID: surfaceID, hasSurfaceIDParam: hasSurfaceIDParam) {
        case .unresolved(let resolution): return resolution
        case .surface(let id): surfaceId = id
        }
        guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
            return .surfaceNotTerminal(surfaceId)
        }
        let sendResult = terminalPanel.sendNamedKeyResult(key)
        switch sendResult {
        case .sent:
            terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceSendKey")
        case .queued:
            break
        case .unknownKey:
            return .unknownKey
        case .inputQueueFull:
            return .inputQueueFull(surfaceId)
        case .surfaceUnavailable:
            return .surfaceUnavailable(surfaceId)
        case .processExited:
            return .processExited(surfaceId)
        }
        return .sent(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceId,
            queued: sendResult == .queued
        )
    }

    // MARK: - read_text

    func controlSurfaceReadText(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        includeScrollback: Bool,
        lineLimit: Int?
    ) -> ControlSurfaceReadTextResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        let surfaceId: UUID
        if hasSurfaceIDParam {
            guard let id = surfaceID else { return .surfaceNotFoundForID }
            surfaceId = id
        } else {
            guard let focused = ws.focusedPanelId else { return .noFocusedSurface }
            surfaceId = focused
        }
        guard let terminalPanel = ws.terminalPanel(for: surfaceId) else {
            return .surfaceNotTerminal(surfaceId)
        }

        guard let rawSnapshot = readTerminalTextRawSnapshot(
            terminalPanel: terminalPanel,
            includeScrollback: includeScrollback
        ) else {
            return .internalError(message: "Failed to read terminal text")
        }
        switch Self.terminalTextPayload(
            from: rawSnapshot,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        ) {
        case .success(let payload):
            return .read(
                text: payload.text,
                base64: payload.base64,
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: ws.id,
                surfaceID: surfaceId
            )
        case .failure(let error):
            return .internalError(message: error.message)
        }
    }

    // MARK: - debug.terminals

    func controlDebugTerminals() -> JSONValue? {
        // The legacy `v2DebugTerminals` builds a dozens-of-fields `[String: Any]`
        // from NSWindow/NSView/Ghostty internals. It is the single irreducibly
        // app-coupled payload in this domain, so we keep the body app-side and
        // bridge its Foundation dictionary to a JSONValue (the documented
        // single-method passthrough). `v2DebugTerminals` ignores its params.
        switch v2DebugTerminals(params: [:]) {
        case let .ok(payload):
            return JSONValue(foundationObject: payload)
        case .err:
            return nil
        }
    }
}
