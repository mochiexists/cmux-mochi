import CmuxHive
import CmuxMobileShellModel
import CmuxTerminal
import Foundation

/// Mounts authenticated remote terminals as ordinary native cmux workspaces.
@MainActor
final class HiveWorkspaceMirrorController {
    @MainActor
    private final class MirrorRecord {
        weak var tabManager: TabManager?
        let workspaceID: UUID
        let sessions: [HiveTerminalSession]
        var lifetimeTask: Task<Void, Never>?

        init(
            tabManager: TabManager,
            workspaceID: UUID,
            sessions: [HiveTerminalSession]
        ) {
            self.tabManager = tabManager
            self.workspaceID = workspaceID
            self.sessions = sessions
        }

        func detach() {
            lifetimeTask?.cancel()
            lifetimeTask = nil
            sessions.forEach { $0.detach() }
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
            macDeviceID: remoteWorkspace.macDeviceID ?? "unknown",
            macInstanceTag: remoteWorkspace.macInstanceTag,
            remoteWorkspaceID: remoteWorkspace.rpcWorkspaceID.rawValue
        )
        if let existing = mirrors[key],
           let workspace = tabManager.workspacesById[existing.workspaceID] {
            tabManager.selectWorkspace(workspace)
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
        var sessions: [HiveTerminalSession] = []
        var selectedPanel: TerminalPanel?

        for (index, terminal) in remoteWorkspace.terminals.enumerated() {
            guard let session = coordinator.makeTerminalSession(
                surfaceID: terminal.id.rawValue
            ) else { continue }
            guard let panel = workspace.addRemoteTmuxDisplayPane(
                remotePaneId: index,
                title: terminal.name,
                focus: false,
                onInput: { input in
                    guard case let .bytes(data) = input else { return }
                    Task { @MainActor in session.send(data) }
                },
                onResize: { columns, rows in
                    Task { @MainActor in
                        _ = await session.resize(columns: columns, rows: rows)
                    }
                }
            ) else { continue }
            session.attach { [weak panel] data in
                panel?.surface.processRemoteOutput(data)
            }
            sessions.append(session)
            if terminal.id == selectedTerminal.id {
                selectedPanel = panel
            }
        }

        guard !sessions.isEmpty else {
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
            sessions: sessions
        )
        mirrors[key] = record
        record.lifetimeTask = Task { @MainActor [weak self, weak record] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let record else { return }
                guard record.tabManager?.workspacesById[record.workspaceID] == nil else {
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
