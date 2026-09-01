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
                  let preparation = session.prepareViewport(
                    columns: columns,
                    rows: rows
                  ) else { return }
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
                guard let effectiveGrid = await self?.session.updatePreparedViewport(preparation)
                else { return }
                panel?.surface.setAssignedGrid(
                    columns: effectiveGrid.columns,
                    rows: effectiveGrid.rows
                )
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
        let panelIDByRemoteSurfaceID: [String: UUID]
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
        pruneClosedMirrors()
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
            if let panelID = existing.panelIDByRemoteSurfaceID[selectedTerminal.id.rawValue] {
                workspace.focusPanel(panelID)
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
            guard let session = coordinator.makeTerminalSession(
                surfaceID: terminal.id.rawValue
            ) else { continue }
            let inputRelay = InputRelay()
            guard let panel = workspace.addRemoteTmuxDisplayPane(
                remotePaneId: index,
                title: terminal.name,
                focus: false,
                onInput: { input in
                    inputRelay.send(input)
                }
            ) else { continue }
            let binding = TerminalBinding(session: session, panel: panel)
            inputRelay.forward(to: binding)
            binding.start()
            bindingsByPanelID[panel.id] = binding
            panelIDByRemoteSurfaceID[terminal.id.rawValue] = panel.id
            if terminal.id == selectedTerminal.id {
                selectedPanel = panel
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
                guard !record.reconcilePanels() else {
                    continue
                }
                record.detach()
                self.mirrors.removeValue(forKey: key)
                return
            }
        }
    }

    private func pruneClosedMirrors() {
        for (key, record) in mirrors
        where record.tabManager?.workspacesById[record.workspaceID] == nil {
            record.detach()
            mirrors.removeValue(forKey: key)
        }
    }
}
