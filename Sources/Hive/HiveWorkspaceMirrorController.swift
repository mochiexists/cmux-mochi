import CmuxHive
import CmuxCore
import CmuxMobileShellModel
import CmuxTerminal
import Foundation
import os

/// Mounts authenticated remote terminals as ordinary native cmux workspaces.
@MainActor
final class HiveWorkspaceMirrorController {
    struct OpenResult {
        let workspaceID: UUID
        let localPanelIDsByRemoteSurfaceID: [String: UUID]
    }

    struct AttachmentStatus {
        let remoteWorkspaceID: String
        let remoteSurfaceID: String
        let localMountCount: Int
        let remoteRegistrationCount: Int
    }

    @MainActor
    private final class TerminalBinding {
        let panelID: UUID
        weak var panel: TerminalPanel?
        weak var attachment: TerminalAttachment?
        private let inputForwarder: RemoteTmuxPaneInputForwarder
        private var outputSubscription: HiveTerminalSession.Subscription?

        init(attachment: TerminalAttachment, panel: TerminalPanel) {
            panelID = panel.id
            self.attachment = attachment
            self.panel = panel
            inputForwarder = RemoteTmuxPaneInputForwarder(
                onInput: { [weak attachment] input, _ in
                    guard case let .bytes(data) = input else { return }
                    attachment?.send(data)
                },
                onOverflow: { [weak attachment] in
                    attachment?.stopOutput()
                }
            )
        }

        nonisolated func send(_ input: TerminalManualInput) {
            _ = inputForwarder.send(input, toPane: 0)
        }

        func start() {
            guard let panel else { return }
            attachment?.add(self)
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
            guard let sample = panel?.surface.rawSizingSample() else { return }
            applyViewport(columns: sample.columns, rows: sample.rows)
        }

        func detach() {
            inputForwarder.setConnectionActive(false)
            panel?.surface.onManualSizeApplied = nil
            panel?.surface.onRuntimeReady = nil
            panel?.surface.clearAssignedGrid()
            attachment?.remove(self)
            attachment = nil
        }

        func subscribe(to session: HiveTerminalSession) {
            guard outputSubscription == nil else { return }
            outputSubscription = session.subscribe(
                onOutput: { [weak panel] data in
                    panel?.surface.processRemoteOutput(data)
                },
                onEnd: { [weak self] in
                    self?.inputForwarder.setConnectionActive(false)
                }
            )
        }

        func unsubscribe(from session: HiveTerminalSession) {
            guard let outputSubscription else { return }
            self.outputSubscription = nil
            session.detach(outputSubscription)
        }

        func setConnectionActive(_ isActive: Bool) {
            inputForwarder.setConnectionActive(isActive)
        }

        func applyEffectiveGrid(columns: Int, rows: Int) -> Bool {
            panel?.surface.setAssignedGrid(columns: columns, rows: rows) ?? false
        }

        private func applyViewport(columns: Int, rows: Int) {
            attachment?.applyViewport(
                from: self,
                columns: columns,
                rows: rows
            )
        }
    }

    /// Shares one output registration and one ordered resize owner across windows.
    @MainActor
    private final class TerminalAttachment {
        let session: HiveTerminalSession
        private var bindingsByPanelID: [UUID: TerminalBinding] = [:]
        private var bindingOrder: [UUID] = []

        init(session: HiveTerminalSession) {
            self.session = session
        }

        var isEmpty: Bool { bindingsByPanelID.isEmpty }
        var localMountCount: Int { bindingsByPanelID.count }
        var remoteRegistrationCount: Int { session.phase == .attached ? 1 : 0 }

        func add(_ binding: TerminalBinding) {
            let panelID = binding.panelID
            guard bindingsByPanelID[panelID] == nil else { return }
            bindingsByPanelID[panelID] = binding
            bindingOrder.append(panelID)
            binding.subscribe(to: session)
        }

        func remove(_ binding: TerminalBinding) {
            let panelID = binding.panelID
            guard bindingsByPanelID.removeValue(forKey: panelID) != nil else { return }
            let wasOwner = bindingOrder.first == panelID
            bindingOrder.removeAll { $0 == panelID }
            binding.unsubscribe(from: session)
            if wasOwner {
                currentOwner?.reconnectIfNeeded()
            }
        }

        func send(_ data: Data) {
            session.send(data)
        }

        func stopOutput() {
            bindingsByPanelID.values.forEach { $0.setConnectionActive(false) }
            session.stopOutput()
        }

        func applyViewport(
            from binding: TerminalBinding,
            columns: Int,
            rows: Int
        ) {
            guard columns > 1, rows > 1,
                  currentOwner === binding,
                  let preparation = session.prepareViewport(
                    columns: columns,
                    rows: rows
                  ) else { return }
            // The oldest live mount deterministically owns the remote viewport.
            // Every local renderer follows the owner's effective grid, so a
            // differently-sized second window cannot start a resize fight.
            bindingsByPanelID.values.forEach {
                _ = $0.applyEffectiveGrid(columns: columns, rows: rows)
                $0.setConnectionActive(true)
            }
            session.startOutput()
            Task { @MainActor [weak self] in
                guard let self,
                      let effectiveGrid = await self.session.updatePreparedViewport(preparation)
                else { return }
                let grew = self.bindingsByPanelID.values.reduce(false) { result, binding in
                    binding.applyEffectiveGrid(
                        columns: effectiveGrid.columns,
                        rows: effectiveGrid.rows
                    ) || result
                }
                if grew {
                    self.session.refreshVisibleScreen()
                }
            }
        }

        private var currentOwner: TerminalBinding? {
            while let panelID = bindingOrder.first {
                if let binding = bindingsByPanelID[panelID] {
                    return binding
                }
                bindingOrder.removeFirst()
            }
            return nil
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
        weak var coordinator: HiveWorkspaceCoordinator?
        let workspaceID: UUID
        let remoteWorkspaceKey: RemoteWorkspaceKey
        var bindingsByPanelID: [UUID: TerminalBinding]
        var panelIDByRemoteSurfaceID: [String: UUID]
        var knownRemoteSurfaceIDs: Set<String>
        var lifetimeTask: Task<Void, Never>?

        init(
            tabManager: TabManager,
            coordinator: HiveWorkspaceCoordinator,
            workspaceID: UUID,
            remoteWorkspaceKey: RemoteWorkspaceKey,
            bindingsByPanelID: [UUID: TerminalBinding],
            panelIDByRemoteSurfaceID: [String: UUID],
            knownRemoteSurfaceIDs: Set<String>
        ) {
            self.tabManager = tabManager
            self.coordinator = coordinator
            self.workspaceID = workspaceID
            self.remoteWorkspaceKey = remoteWorkspaceKey
            self.bindingsByPanelID = bindingsByPanelID
            self.panelIDByRemoteSurfaceID = panelIDByRemoteSurfaceID
            self.knownRemoteSurfaceIDs = knownRemoteSurfaceIDs
        }

        func detach() {
            lifetimeTask?.cancel()
            lifetimeTask = nil
            bindingsByPanelID.values.forEach { $0.detach() }
            bindingsByPanelID.removeAll()
        }

        func removeClosedLocalPanels(in workspace: Workspace) {
            let closedPanelIDs = bindingsByPanelID.keys.filter {
                workspace.panels[$0] == nil
            }
            for panelID in closedPanelIDs {
                bindingsByPanelID.removeValue(forKey: panelID)?.detach()
                panelIDByRemoteSurfaceID = panelIDByRemoteSurfaceID.filter {
                    $0.value != panelID
                }
            }
        }
    }

    private struct RemoteWorkspaceKey: Hashable {
        let macDeviceID: String
        let macInstanceTag: String?
        let remoteWorkspaceID: String

        init(workspace: MobileWorkspacePreview) {
            macDeviceID = workspace.macDeviceID
                ?? "unknown:\(workspace.id.rawValue)"
            macInstanceTag = workspace.macInstanceTag
            remoteWorkspaceID = workspace.rpcWorkspaceID.rawValue
        }

        func matches(_ workspace: MobileWorkspacePreview) -> Bool {
            self == RemoteWorkspaceKey(workspace: workspace)
        }
    }

    private struct MirrorKey: Hashable {
        let tabManagerID: ObjectIdentifier
        let remoteWorkspace: RemoteWorkspaceKey
    }

    private struct TerminalAttachmentKey: Hashable {
        let remoteWorkspace: RemoteWorkspaceKey
        let remoteSurfaceID: String
    }

    private var mirrors: [MirrorKey: MirrorRecord] = [:]
    private var terminalAttachments: [TerminalAttachmentKey: TerminalAttachment] = [:]

    /// Opens every terminal in a remote workspace.
    ///
    /// Interactive UI callers use the default focus behavior. Automation passes
    /// `false`, preserving the caller's selected workspace and first responder.
    @discardableResult
    func open(
        workspace remoteWorkspace: MobileWorkspacePreview,
        selectedTerminal: MobileTerminalPreview,
        coordinator: HiveWorkspaceCoordinator,
        in tabManager: TabManager,
        focus: Bool = true
    ) -> OpenResult? {
        reconcileMirrors()
        let remoteWorkspaceKey = RemoteWorkspaceKey(workspace: remoteWorkspace)
        let key = MirrorKey(
            tabManagerID: ObjectIdentifier(tabManager),
            remoteWorkspace: remoteWorkspaceKey
        )
        if let existing = mirrors[key],
           let workspace = tabManager.workspacesById[existing.workspaceID] {
            if focus {
                tabManager.selectWorkspace(workspace)
            }
            if let panelID = existing.panelIDByRemoteSurfaceID[selectedTerminal.id.rawValue],
               workspace.panels[panelID] != nil {
                if focus {
                    workspace.focusPanel(panelID)
                }
                return OpenResult(
                    workspaceID: workspace.id,
                    localPanelIDsByRemoteSurfaceID: existing.panelIDByRemoteSurfaceID
                )
            }
            let remotePaneID = remoteWorkspace.terminals.firstIndex {
                $0.id == selectedTerminal.id
            } ?? existing.panelIDByRemoteSurfaceID.count
            if let mounted = mount(
                terminal: selectedTerminal,
                remotePaneID: remotePaneID,
                remoteWorkspaceKey: remoteWorkspaceKey,
                coordinator: coordinator,
                in: workspace
            ) {
                existing.bindingsByPanelID[mounted.panel.id] = mounted.binding
                existing.panelIDByRemoteSurfaceID[selectedTerminal.id.rawValue] = mounted.panel.id
                if focus {
                    workspace.focusPanel(mounted.panel.id)
                }
            }
            return OpenResult(
                workspaceID: workspace.id,
                localPanelIDsByRemoteSurfaceID: existing.panelIDByRemoteSurfaceID
            )
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
        let remoteWorkspaceID = remoteWorkspace.rpcWorkspaceID
        workspace.configureHiveMirror(
            remoteDisplayName: computerName,
            requestNewTerminal: { [weak coordinator] in
                coordinator?.createTerminal(in: remoteWorkspaceID)
            },
            requestWorkspaceRename: { [weak coordinator] title in
                Task { @MainActor in
                    _ = await coordinator?.renameWorkspace(
                        id: remoteWorkspaceID,
                        title: title
                    )
                }
            }
        )
        let defaultPanelIDs = Array(workspace.panels.keys)
        var bindingsByPanelID: [UUID: TerminalBinding] = [:]
        var panelIDByRemoteSurfaceID: [String: UUID] = [:]
        var selectedPanel: TerminalPanel?

        for (index, terminal) in remoteWorkspace.terminals.enumerated() {
            guard let mounted = mount(
                terminal: terminal,
                remotePaneID: index,
                remoteWorkspaceKey: remoteWorkspaceKey,
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
            return nil
        }
        for panelID in defaultPanelIDs where workspace.panels[panelID] != nil {
            _ = workspace.removeRemoteTmuxDisplayPane(panelID)
        }
        if focus {
            tabManager.selectWorkspace(workspace)
            if let selectedPanel {
                workspace.focusPanel(selectedPanel.id)
            }
        }

        let record = MirrorRecord(
            tabManager: tabManager,
            coordinator: coordinator,
            workspaceID: workspace.id,
            remoteWorkspaceKey: remoteWorkspaceKey,
            bindingsByPanelID: bindingsByPanelID,
            panelIDByRemoteSurfaceID: panelIDByRemoteSurfaceID,
            knownRemoteSurfaceIDs: Set(remoteWorkspace.terminals.map { $0.id.rawValue })
        )
        mirrors[key] = record
        applyConnectionPresentation(
            connectionState(for: record, coordinator: coordinator),
            to: workspace,
            record: record
        )
        updateMountedWorkspaceCount(for: coordinator)
        record.lifetimeTask = Task { @MainActor [weak self, weak record] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let record else { return }
                guard self.reconcileMirror(record, for: key) else { return }
            }
        }
        return OpenResult(
            workspaceID: workspace.id,
            localPanelIDsByRemoteSurfaceID: panelIDByRemoteSurfaceID
        )
    }

    private func mount(
        terminal: MobileTerminalPreview,
        remotePaneID: Int,
        remoteWorkspaceKey: RemoteWorkspaceKey,
        coordinator: HiveWorkspaceCoordinator,
        in workspace: Workspace
    ) -> (panel: TerminalPanel, binding: TerminalBinding)? {
        let attachmentKey = TerminalAttachmentKey(
            remoteWorkspace: remoteWorkspaceKey,
            remoteSurfaceID: terminal.id.rawValue
        )
        let attachment: TerminalAttachment
        if let existing = terminalAttachments[attachmentKey] {
            attachment = existing
        } else {
            guard let session = coordinator.makeTerminalSession(
                surfaceID: terminal.id.rawValue
            ) else { return nil }
            let created = TerminalAttachment(session: session)
            terminalAttachments[attachmentKey] = created
            attachment = created
        }
        let inputRelay = InputRelay()
        guard let panel = workspace.addRemoteTmuxDisplayPane(
            remotePaneId: remotePaneID,
            title: terminal.name,
            focus: false,
            onInput: { input in
                inputRelay.send(input)
            }
        ) else { return nil }
        let binding = TerminalBinding(attachment: attachment, panel: panel)
        inputRelay.forward(to: binding)
        binding.start()
        return (panel, binding)
    }

    @discardableResult
    private func reconcileMirror(_ record: MirrorRecord, for key: MirrorKey) -> Bool {
        guard mirrors[key] === record else { return false }
        guard let tabManager = record.tabManager,
              let workspace = tabManager.workspacesById[record.workspaceID],
              let coordinator = record.coordinator else {
            removeMirror(record, for: key, workspace: nil)
            return false
        }

        record.removeClosedLocalPanels(in: workspace)
        guard !record.bindingsByPanelID.isEmpty else {
            removeMirror(record, for: key, workspace: workspace)
            return false
        }
        let connectionState = connectionState(for: record, coordinator: coordinator)
        applyConnectionPresentation(connectionState, to: workspace, record: record)
        guard let remoteWorkspace = coordinator.workspaces.first(where: {
            record.remoteWorkspaceKey.matches($0)
        }) else {
            if connectionState != .connected {
                return true
            }
            removeMirror(record, for: key, workspace: workspace)
            return false
        }

        let currentRemoteSurfaceIDs = Set(
            remoteWorkspace.terminals.map { $0.id.rawValue }
        )
        let removedRemoteSurfaceIDs = record.knownRemoteSurfaceIDs
            .subtracting(currentRemoteSurfaceIDs)
        for remoteSurfaceID in removedRemoteSurfaceIDs {
            guard let panelID = record.panelIDByRemoteSurfaceID.removeValue(
                forKey: remoteSurfaceID
            ) else { continue }
            record.bindingsByPanelID.removeValue(forKey: panelID)?.detach()
            if workspace.panels[panelID] != nil {
                _ = workspace.removeRemoteTmuxDisplayPane(panelID)
            }
        }

        let addedRemoteSurfaceIDs = currentRemoteSurfaceIDs
            .subtracting(record.knownRemoteSurfaceIDs)
        for (index, terminal) in remoteWorkspace.terminals.enumerated()
            where addedRemoteSurfaceIDs.contains(terminal.id.rawValue) {
            guard let mounted = mount(
                terminal: terminal,
                remotePaneID: index,
                remoteWorkspaceKey: record.remoteWorkspaceKey,
                coordinator: coordinator,
                in: workspace
            ) else { continue }
            record.bindingsByPanelID[mounted.panel.id] = mounted.binding
            record.panelIDByRemoteSurfaceID[terminal.id.rawValue] = mounted.panel.id
        }

        for terminal in remoteWorkspace.terminals {
            guard let panelID = record.panelIDByRemoteSurfaceID[terminal.id.rawValue]
            else { continue }
            workspace.updateRemoteTmuxTabTitle(
                panelId: panelID,
                title: terminal.name
            )
        }
        record.knownRemoteSurfaceIDs = currentRemoteSurfaceIDs

        guard !record.bindingsByPanelID.isEmpty else {
            removeMirror(record, for: key, workspace: workspace)
            return false
        }
        applyConnectionPresentation(connectionState, to: workspace, record: record)
        record.bindingsByPanelID.values.forEach { $0.reconnectIfNeeded() }
        pruneTerminalAttachments()
        return true
    }

    private func removeMirror(
        _ record: MirrorRecord,
        for key: MirrorKey,
        workspace: Workspace?
    ) {
        record.detach()
        mirrors.removeValue(forKey: key)
        let coordinator = record.coordinator
        if let workspace, let tabManager = record.tabManager {
            if tabManager.tabs.count > 1 {
                tabManager.closeWorkspace(workspace, recordHistory: false)
            } else {
                // Closing the last panel in the last workspace creates a local
                // replacement. Release Hive policy so that replacement works.
                workspace.detachRemoteTmuxMirrorKeptOpenLocallyIfNeeded()
            }
        }
        pruneTerminalAttachments()
        if let coordinator {
            updateMountedWorkspaceCount(for: coordinator)
        }
    }

    private func pruneTerminalAttachments() {
        terminalAttachments = terminalAttachments.filter { !$0.value.isEmpty }
    }

    func reconcileMirrors() {
        for (key, record) in Array(mirrors) {
            _ = reconcileMirror(record, for: key)
        }
    }

    func isMounted(
        workspace: MobileWorkspacePreview,
        terminal: MobileTerminalPreview
    ) -> Bool {
        let key = TerminalAttachmentKey(
            remoteWorkspace: RemoteWorkspaceKey(workspace: workspace),
            remoteSurfaceID: terminal.id.rawValue
        )
        return terminalAttachments[key]?.localMountCount ?? 0 > 0
    }

    private func connectionState(
        for record: MirrorRecord,
        coordinator: HiveWorkspaceCoordinator
    ) -> WorkspaceRemoteConnectionState {
        if let workspace = coordinator.workspaces.first(where: {
            record.remoteWorkspaceKey.matches($0)
        }), let status = workspace.macConnectionStatus {
            return connectionState(for: status)
        }
        if let mac = coordinator.pairedMacs.first(where: {
            $0.macDeviceID == record.remoteWorkspaceKey.macDeviceID
                && $0.instanceTag == record.remoteWorkspaceKey.macInstanceTag
        }) {
            return connectionState(for: coordinator.connectionStatus(for: mac))
        }
        return switch coordinator.phase {
        case .connected:
            .connected
        case .pairing, .connecting:
            .reconnecting
        case .idle, .pairedOffline, .failed:
            .disconnected
        }
    }

    private func connectionState(
        for status: MobileMacConnectionStatus
    ) -> WorkspaceRemoteConnectionState {
        switch status {
        case .connected:
            .connected
        case .reconnecting:
            .reconnecting
        case .unavailable:
            .disconnected
        }
    }

    private func applyConnectionPresentation(
        _ state: WorkspaceRemoteConnectionState,
        to workspace: Workspace,
        record: MirrorRecord
    ) {
        workspace.remoteConnectionState = state
        workspace.remoteConnectionDetail = record.coordinator?.connectionDetail
        for binding in record.bindingsByPanelID.values {
            binding.panel?.hiveConnectionState = state
            binding.setConnectionActive(state == .connected)
        }
    }

    private func updateMountedWorkspaceCount(for coordinator: HiveWorkspaceCoordinator) {
        let count = mirrors.values.reduce(into: 0) { result, record in
            if record.coordinator === coordinator {
                result += 1
            }
        }
        coordinator.setMountedWorkspaceCount(count)
    }

    func statusSnapshot() -> [AttachmentStatus] {
        reconcileMirrors()
        return terminalAttachments.map { key, attachment in
            AttachmentStatus(
                remoteWorkspaceID: key.remoteWorkspace.remoteWorkspaceID,
                remoteSurfaceID: key.remoteSurfaceID,
                localMountCount: attachment.localMountCount,
                remoteRegistrationCount: attachment.remoteRegistrationCount
            )
        }
        .sorted {
            ($0.remoteWorkspaceID, $0.remoteSurfaceID)
                < ($1.remoteWorkspaceID, $1.remoteSurfaceID)
        }
    }
}
