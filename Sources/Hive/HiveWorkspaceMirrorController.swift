import CmuxHive
import CmuxMobileShellModel
import CmuxTerminal
import Foundation
import os

/// Mounts authenticated remote terminals as ordinary native cmux workspaces.
@MainActor
final class HiveWorkspaceMirrorController {
    @MainActor
    private final class TerminalBinding {
        let session: HiveTerminalSession
        weak var panel: TerminalPanel?
        private let inputForwarder: RemoteTmuxPaneInputForwarder

        init(session: HiveTerminalSession, panel: TerminalPanel) {
            self.session = session
            self.panel = panel
            inputForwarder = RemoteTmuxPaneInputForwarder(
                onInput: { input, _ in
                    guard case let .bytes(data) = input else { return }
                    session.send(data)
                },
                onOverflow: {
                    session.detach()
                }
            )
        }

        nonisolated func send(_ input: TerminalManualInput) {
            _ = inputForwarder.send(input, toPane: 0)
        }

        func start() {
            guard let panel else { return }
            panel.surface.setManualIONoReflow(true)
            panel.surface.onManualSizeApplied = { [weak self] sample in
                self?.applyViewport(columns: sample.columns, rows: sample.rows)
            }
            panel.surface.onRuntimeReady = { [weak self, weak panel] in
                guard let sample = panel?.surface.rawSizingSample() else { return }
                self?.applyViewport(columns: sample.columns, rows: sample.rows)
            }
            panel.surface.flushPendingManualSizeReportIfAttached()
            if let sample = panel.surface.rawSizingSample() {
                applyViewport(columns: sample.columns, rows: sample.rows)
            }
        }

        func reconnectIfNeeded() {
            guard session.phase == .idle,
                  let sample = panel?.surface.rawSizingSample() else { return }
            applyViewport(columns: sample.columns, rows: sample.rows)
        }

        func detach() {
            inputForwarder.setConnectionActive(false)
            session.detach()
            panel?.surface.onManualSizeApplied = nil
            panel?.surface.onRuntimeReady = nil
            panel?.surface.clearAssignedGrid()
        }

        private func applyViewport(columns: Int, rows: Int) {
            guard columns > 1, rows > 1,
                  let panel,
                  let preparation = session.prepareViewport(
                    columns: columns,
                    rows: rows
                  ) else { return }
            // Pin the local renderer before the host captures its replacement
            // replay. Otherwise a grow can replay into the old grid and leave
            // the newly assigned cells empty until incidental remote output.
            _ = panel.surface.setAssignedGrid(columns: columns, rows: rows)
            if session.phase == .idle {
                inputForwarder.setConnectionActive(true)
                session.attach(
                    onOutput: { [weak panel] data in
                        panel?.surface.processRemoteOutput(data)
                    },
                    onEnd: { [weak self] in
                        self?.inputForwarder.setConnectionActive(false)
                    }
                )
            }
            Task { @MainActor [weak self, weak panel] in
                guard let self,
                      let panel,
                      let effectiveGrid = await self.session.updatePreparedViewport(preparation)
                else { return }
                let grew = panel.surface.setAssignedGrid(
                    columns: effectiveGrid.columns,
                    rows: effectiveGrid.rows
                )
                if grew {
                    self.session.refreshVisibleScreen()
                }
            }
        }
    }

    private final class InputRelay: Sendable {
        private struct State: @unchecked Sendable {
            weak var binding: TerminalBinding?
        }

        private let state = OSAllocatedUnfairLock(
            initialState: State()
        )

        @MainActor
        func forward(to binding: TerminalBinding) {
            state.withLock { $0.binding = binding }
        }

        nonisolated func send(_ input: TerminalManualInput) {
            state.withLock { $0.binding?.send(input) }
        }
    }

    @MainActor
    private final class MirrorRecord {
        weak var tabManager: TabManager?
        let workspaceID: UUID
        var bindingsByPanelID: [UUID: TerminalBinding]
        var panelIDByRemoteSurfaceID: [String: UUID]
        var lifetimeTask: Task<Void, Never>?

        init(
            tabManager: TabManager,
            workspaceID: UUID,
            bindingsByPanelID: [UUID: TerminalBinding],
            panelIDByRemoteSurfaceID: [String: UUID]
        ) {
            self.tabManager = tabManager
            self.workspaceID = workspaceID
            self.bindingsByPanelID = bindingsByPanelID
            self.panelIDByRemoteSurfaceID = panelIDByRemoteSurfaceID
        }

        func detach() {
            lifetimeTask?.cancel()
            lifetimeTask = nil
            bindingsByPanelID.values.forEach { $0.detach() }
            bindingsByPanelID.removeAll()
        }

        func reconcilePanels() -> Bool {
            guard let workspace = tabManager?.workspacesById[workspaceID] else {
                return false
            }
            let closedPanelIDs = bindingsByPanelID.keys.filter {
                workspace.panels[$0] == nil
            }
            for panelID in closedPanelIDs {
                bindingsByPanelID.removeValue(forKey: panelID)?.detach()
                panelIDByRemoteSurfaceID = panelIDByRemoteSurfaceID.filter {
                    $0.value != panelID
                }
            }
            guard !bindingsByPanelID.isEmpty else {
                guard let tabManager else { return false }
                if tabManager.tabs.count > 1 {
                    tabManager.closeWorkspace(workspace, recordHistory: false)
                } else {
                    // Workspace.closePanel creates a replacement local terminal
                    // when the final pane in the final workspace is removed.
                    // The mirror controller must release the remote-only policy
                    // in that case or the replacement remains a stuck mirror.
                    workspace.detachRemoteTmuxMirrorKeptOpenLocallyIfNeeded()
                }
                return false
            }
            bindingsByPanelID.values.forEach { $0.reconnectIfNeeded() }
            return true
        }
    }

    private struct MirrorKey: Hashable {
        let tabManagerID: ObjectIdentifier
        let macDeviceID: String
        let macInstanceTag: String?
        let remoteWorkspaceID: String
    }

    private var mirrors: [MirrorKey: MirrorRecord] = [:]

    /// Opens every terminal in a remote workspace and focuses the chosen one.
    func open(
        workspace remoteWorkspace: MobileWorkspacePreview,
        selectedTerminal: MobileTerminalPreview,
        coordinator: HiveWorkspaceCoordinator,
        in tabManager: TabManager
    ) {
        reconcileMirrors()
        let key = MirrorKey(
            tabManagerID: ObjectIdentifier(tabManager),
            macDeviceID: remoteWorkspace.macDeviceID
                ?? "unknown:\(remoteWorkspace.id.rawValue)",
            macInstanceTag: remoteWorkspace.macInstanceTag,
            remoteWorkspaceID: remoteWorkspace.rpcWorkspaceID.rawValue
        )
        if let existing = mirrors[key],
           let workspace = tabManager.workspacesById[existing.workspaceID] {
            tabManager.selectWorkspace(workspace)
            if let panelID = existing.panelIDByRemoteSurfaceID[selectedTerminal.id.rawValue],
               workspace.panels[panelID] != nil {
                workspace.focusPanel(panelID)
                return
            }
            let remotePaneID = remoteWorkspace.terminals.firstIndex {
                $0.id == selectedTerminal.id
            } ?? existing.panelIDByRemoteSurfaceID.count
            if let mounted = mount(
                terminal: selectedTerminal,
                remotePaneID: remotePaneID,
                coordinator: coordinator,
                in: workspace
            ) {
                existing.bindingsByPanelID[mounted.panel.id] = mounted.binding
                existing.panelIDByRemoteSurfaceID[selectedTerminal.id.rawValue] = mounted.panel.id
                workspace.focusPanel(mounted.panel.id)
            }
            return
        }

        let computerName = remoteWorkspace.macDisplayName
            ?? String((remoteWorkspace.macDeviceID ?? "remote").prefix(8))
        let titleTemplate = String(
            localized: "hive.mirror.workspaceTitle",
            defaultValue: "%1$@ — %2$@"
        )
        let title = String.localizedStringWithFormat(
            titleTemplate,
            remoteWorkspace.name,
            computerName
        )
        let workspace = tabManager.addWorkspace(
            title: title,
            select: false,
            autoWelcomeIfNeeded: false,
            autoRefreshMetadata: false
        )
        workspace.isRemoteTmuxMirror = true
        let defaultPanelIDs = Array(workspace.panels.keys)
        var bindingsByPanelID: [UUID: TerminalBinding] = [:]
        var panelIDByRemoteSurfaceID: [String: UUID] = [:]
        var selectedPanel: TerminalPanel?

        for (index, terminal) in remoteWorkspace.terminals.enumerated() {
            guard let mounted = mount(
                terminal: terminal,
                remotePaneID: index,
                coordinator: coordinator,
                in: workspace
            ) else { continue }
            bindingsByPanelID[mounted.panel.id] = mounted.binding
            panelIDByRemoteSurfaceID[terminal.id.rawValue] = mounted.panel.id
            if terminal.id == selectedTerminal.id {
                selectedPanel = mounted.panel
            }
        }

        guard !bindingsByPanelID.isEmpty else {
            tabManager.closeWorkspace(workspace, recordHistory: false)
            return
        }
        for panelID in defaultPanelIDs where workspace.panels[panelID] != nil {
            _ = workspace.removeRemoteTmuxDisplayPane(panelID)
        }
        tabManager.selectWorkspace(workspace)
        if let selectedPanel {
            workspace.focusPanel(selectedPanel.id)
        }

        let record = MirrorRecord(
            tabManager: tabManager,
            workspaceID: workspace.id,
            bindingsByPanelID: bindingsByPanelID,
            panelIDByRemoteSurfaceID: panelIDByRemoteSurfaceID
        )
        mirrors[key] = record
        record.lifetimeTask = Task { @MainActor [weak self, weak record] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let record else { return }
                guard self.reconcileMirror(record, for: key) else { return }
            }
        }
    }

    private func mount(
        terminal: MobileTerminalPreview,
        remotePaneID: Int,
        coordinator: HiveWorkspaceCoordinator,
        in workspace: Workspace
    ) -> (panel: TerminalPanel, binding: TerminalBinding)? {
        guard let session = coordinator.makeTerminalSession(
            surfaceID: terminal.id.rawValue
        ) else { return nil }
        let inputRelay = InputRelay()
        guard let panel = workspace.addRemoteTmuxDisplayPane(
            remotePaneId: remotePaneID,
            title: terminal.name,
            focus: false,
            onInput: { input in
                inputRelay.send(input)
            }
        ) else { return nil }
        let binding = TerminalBinding(session: session, panel: panel)
        inputRelay.forward(to: binding)
        binding.start()
        return (panel, binding)
    }

    @discardableResult
    private func reconcileMirror(_ record: MirrorRecord, for key: MirrorKey) -> Bool {
        guard mirrors[key] === record else { return false }
        guard record.reconcilePanels() else {
            record.detach()
            mirrors.removeValue(forKey: key)
            return false
        }
        return true
    }

    func reconcileMirrors() {
        for (key, record) in Array(mirrors) {
            _ = reconcileMirror(record, for: key)
        }
    }
}
