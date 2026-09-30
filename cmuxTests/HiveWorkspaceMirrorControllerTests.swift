import CMUXMobileCore
import CmuxHive
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxTerminal
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct HiveWorkspaceMirrorControllerTests {
    @Test("one window owns remote resize reports for a shared terminal")
    func sharesRemoteTerminalResizeOwnershipAcrossWindows() throws {
        let terminal = MobileTerminalPreview(id: "surface-a", name: "Alpha")
        var remoteWorkspace = MobileWorkspacePreview(
            id: "remote-workspace",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Remote",
            terminals: [terminal]
        )
        remoteWorkspace.macInstanceTag = "dev-a"
        let shell = HiveWorkspaceMirrorShellStub(workspaces: [remoteWorkspace])
        let coordinator = HiveWorkspaceCoordinator(shell: shell)
        let controller = HiveWorkspaceMirrorController()
        let firstManager = TabManager()
        let secondManager = TabManager()

        controller.open(
            workspace: remoteWorkspace,
            selectedTerminal: terminal,
            coordinator: coordinator,
            in: firstManager
        )
        controller.open(
            workspace: remoteWorkspace,
            selectedTerminal: terminal,
            coordinator: coordinator,
            in: secondManager
        )

        let firstMirror = try #require(firstManager.tabs.first { $0.isHiveWorkspaceMirror })
        let secondMirror = try #require(secondManager.tabs.first { $0.isHiveWorkspaceMirror })
        let firstPanelID = try #require(firstMirror.focusedPanelId)
        let secondPanelID = try #require(secondMirror.focusedPanelId)
        let firstPanel = try #require(firstMirror.terminalPanel(for: firstPanelID))
        let secondPanel = try #require(secondMirror.terminalPanel(for: secondPanelID))

        secondPanel.surface.onManualSizeApplied?(Self.sizingSample(columns: 120, rows: 40))
        firstPanel.surface.onManualSizeApplied?(Self.sizingSample(columns: 80, rows: 24))

        #expect(shell.preparedViewports == [
            .init(surfaceID: terminal.id.rawValue, columns: 80, rows: 24),
        ])
        let attachments = controller.statusSnapshot().filter {
            $0.remoteSurfaceID == terminal.id.rawValue
        }
        let attachment = try #require(attachments.first)
        #expect(attachments.count == 1)
        #expect(attachment.localMountCount == 2)
        // The test double cannot mint MobileTerminalViewportPreparation's
        // opaque production token, so it deliberately stops before output
        // registration. The E2E test asserts the live registration count.
        #expect(attachment.remoteRegistrationCount == 0)
    }

    @Test("automation opens a mirror without changing workspace selection")
    func automationOpenPreservesWorkspaceSelection() throws {
        let terminal = MobileTerminalPreview(id: "surface-a", name: "Alpha")
        var remoteWorkspace = MobileWorkspacePreview(
            id: "remote-workspace",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Remote",
            terminals: [terminal]
        )
        remoteWorkspace.macInstanceTag = "dev-a"
        let shell = HiveWorkspaceMirrorShellStub(workspaces: [remoteWorkspace])
        let coordinator = HiveWorkspaceCoordinator(shell: shell)
        let controller = HiveWorkspaceMirrorController()
        let manager = TabManager()
        let originalWorkspaceID = try #require(manager.selectedWorkspace?.id)

        let opened = try #require(controller.open(
            workspace: remoteWorkspace,
            selectedTerminal: terminal,
            coordinator: coordinator,
            in: manager,
            focus: false
        ))

        #expect(manager.selectedWorkspace?.id == originalWorkspaceID)
        #expect(opened.workspaceID != originalWorkspaceID)
        #expect(opened.localPanelIDsByRemoteSurfaceID[terminal.id.rawValue] != nil)
    }

    @Test("reconciles terminals added to and closed from the remote workspace")
    func reconcilesRemoteTerminalTopology() throws {
        let first = MobileTerminalPreview(id: "surface-a", name: "Alpha")
        let second = MobileTerminalPreview(id: "surface-b", name: "Beta")
        var remoteWorkspace = MobileWorkspacePreview(
            id: "remote-workspace",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Remote",
            terminals: [first]
        )
        remoteWorkspace.macInstanceTag = "dev-a"
        let shell = HiveWorkspaceMirrorShellStub(workspaces: [remoteWorkspace])
        let coordinator = HiveWorkspaceCoordinator(shell: shell)
        let controller = HiveWorkspaceMirrorController()
        let manager = TabManager()

        controller.open(
            workspace: remoteWorkspace,
            selectedTerminal: first,
            coordinator: coordinator,
            in: manager
        )
        let mirror = try #require(manager.tabs.first { $0.isHiveWorkspaceMirror })
        #expect(mirror.panels.count == 1)

        remoteWorkspace.terminals = [first, second]
        shell.workspaces = [remoteWorkspace]
        coordinator.refreshWorkspaceSnapshot()
        controller.reconcileMirrors()

        #expect(mirror.panels.count == 2)

        remoteWorkspace.terminals = [second]
        shell.workspaces = [remoteWorkspace]
        coordinator.refreshWorkspaceSnapshot()
        controller.reconcileMirrors()

        #expect(mirror.panels.count == 1)
        let remainingPanelID = try #require(mirror.panels.keys.first)
        #expect(mirror.panelTitle(panelId: remainingPanelID) == second.name)
    }

    @Test("host workspace list excludes Hive mirrors")
    func hostWorkspaceListExcludesHiveMirrors() throws {
        let manager = TabManager()
        let localWorkspace = try #require(manager.selectedWorkspace)
        localWorkspace.title = "Local"
        let mirroredWorkspace = manager.addWorkspace(
            title: "Mirrored",
            select: false,
            autoWelcomeIfNeeded: false,
            autoRefreshMetadata: false
        )
        mirroredWorkspace.isHiveWorkspaceMirror = true

        let result = TerminalController.shared.v2MobileWorkspaceList(
            params: [:],
            tabManager: manager
        )
        guard case let .ok(rawPayload) = result,
              let payload = rawPayload as? [String: Any],
              let workspaces = payload["workspaces"] as? [[String: Any]]
        else {
            Issue.record("Expected a workspace-list payload")
            return
        }

        #expect(workspaces.compactMap { $0["id"] as? String } == [localWorkspace.id.uuidString])
    }

    @Test("routes Hive mutations independently of SSH/tmux mirrors")
    func routesHiveMutations() throws {
        let terminal = MobileTerminalPreview(id: "surface-a", name: "Alpha")
        var remoteWorkspace = MobileWorkspacePreview(
            id: "remote-workspace",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Remote",
            terminals: [terminal]
        )
        remoteWorkspace.macInstanceTag = "dev-a"
        let shell = HiveWorkspaceMirrorShellStub(workspaces: [remoteWorkspace])
        let coordinator = HiveWorkspaceCoordinator(shell: shell)
        let controller = HiveWorkspaceMirrorController()
        let manager = TabManager()

        controller.open(
            workspace: remoteWorkspace,
            selectedTerminal: terminal,
            coordinator: coordinator,
            in: manager
        )

        let mirror = try #require(manager.tabs.first { $0.isHiveWorkspaceMirror })
        #expect(mirror.isRemoteTmuxMirror)
        #expect(mirror.remoteMirrorMutationRoute(for: .newTerminalTab) == .hive)
        #expect(mirror.remoteMirrorMutationRoute(for: .workspaceRename) == .hive)
        #expect(mirror.remoteMirrorMutationRoute(for: .split) == .unavailable)
        #expect(mirror.remoteMirrorMutationRoute(for: .terminalTabRename) == .unavailable)
        #expect(!mirror.bonsplitController.configuration.allowSplits)

        let paneID = try #require(mirror.bonsplitController.focusedPaneId)
        let outcome = mirror.newTerminalSurfaceOutcome(inPane: paneID)
        guard case .routedToRemote = outcome else {
            Issue.record("Expected Hive new-terminal action to route to the host RPC")
            return
        }
        #expect(shell.createdTerminalWorkspaceIDs == [remoteWorkspace.rpcWorkspaceID])
    }

    @Test("reopens a locally closed remote terminal in its existing workspace")
    func reopensClosedTerminal() throws {
        let first = MobileTerminalPreview(id: "surface-a", name: "Alpha")
        let second = MobileTerminalPreview(id: "surface-b", name: "Beta")
        var remoteWorkspace = MobileWorkspacePreview(
            id: "remote-workspace",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Remote",
            terminals: [first, second]
        )
        remoteWorkspace.macInstanceTag = "dev-a"
        let shell = HiveWorkspaceMirrorShellStub(workspaces: [remoteWorkspace])
        let coordinator = HiveWorkspaceCoordinator(shell: shell)
        let controller = HiveWorkspaceMirrorController()
        let manager = TabManager()

        controller.open(
            workspace: remoteWorkspace,
            selectedTerminal: first,
            coordinator: coordinator,
            in: manager
        )
        let mirror = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })
        let closedPanelID = try #require(mirror.focusedPanelId)
        #expect(mirror.panels.count == 2)
        #expect(mirror.removeRemoteTmuxDisplayPane(closedPanelID))

        controller.open(
            workspace: remoteWorkspace,
            selectedTerminal: first,
            coordinator: coordinator,
            in: manager
        )

        #expect(manager.tabs.contains(where: { $0.id == mirror.id }))
        #expect(mirror.panels.count == 2)
        #expect(mirror.focusedPanelId != closedPanelID)
    }

    @Test("releases mirror mode when the last remote pane closes in the last workspace")
    func releasesLastWorkspaceAfterAllRemotePanesClose() throws {
        let terminal = MobileTerminalPreview(id: "surface-a", name: "Alpha")
        var remoteWorkspace = MobileWorkspacePreview(
            id: "remote-workspace",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Remote",
            terminals: [terminal]
        )
        remoteWorkspace.macInstanceTag = "dev-a"
        let shell = HiveWorkspaceMirrorShellStub(workspaces: [remoteWorkspace])
        let coordinator = HiveWorkspaceCoordinator(shell: shell)
        let controller = HiveWorkspaceMirrorController()
        let manager = TabManager()

        controller.open(
            workspace: remoteWorkspace,
            selectedTerminal: terminal,
            coordinator: coordinator,
            in: manager
        )
        let mirror = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })
        for workspace in manager.tabs where workspace.id != mirror.id {
            manager.closeWorkspace(workspace, recordHistory: false)
        }
        let remotePanelID = try #require(mirror.focusedPanelId)

        #expect(mirror.removeRemoteTmuxDisplayPane(remotePanelID))
        controller.reconcileMirrors()

        #expect(manager.tabs.count == 1)
        #expect(manager.tabs.first?.id == mirror.id)
        #expect(!mirror.isRemoteTmuxMirror)
        #expect(mirror.panels.count == 1)
    }

    private static func sizingSample(columns: Int, rows: Int) -> TerminalSurfaceRawSizingSample {
        TerminalSurfaceRawSizingSample(
            columns: columns,
            rows: rows,
            cellWidthPx: 8,
            cellHeightPx: 16,
            surfaceWidthPx: columns * 8,
            surfaceHeightPx: rows * 16,
            viewBoundsPt: nil,
            backingScale: nil
        )
    }
}

@MainActor
private final class HiveWorkspaceMirrorShellStub: HiveShellServing, HiveTerminalShellServing {
    struct PreparedViewport: Equatable {
        let surfaceID: String
        let columns: Int
        let rows: Int
    }

    var workspaces: [MobileWorkspacePreview]
    var connectionError: String?
    var connectionErrorGuidance: String?
    var hasKnownHivePairing = true
    var isHiveMacConnected = true
    var hiveConnectionState: MobileConnectionState = .connected
    var hiveMacConnectionStatus: MobileMacConnectionStatus = .connected
    var hiveIsReconnecting = false
    var hiveActiveRoute: CmxAttachRoute?
    var hivePairedMacs: [MobilePairedMac] = []
    private(set) var createdTerminalWorkspaceIDs: [MobileWorkspacePreview.ID?] = []
    private(set) var preparedViewports: [PreparedViewport] = []
    private(set) var outputRegistrationCountBySurfaceID: [String: Int] = [:]
    private var outputContinuations: [UUID: AsyncStream<MobileTerminalOutputChunk>.Continuation] = [:]

    init(workspaces: [MobileWorkspacePreview]) {
        self.workspaces = workspaces
    }

    func connectPairingURLResult(_ rawValue: String?) async -> MobilePairingURLConnectionResult {
        .connected
    }

    func reconnectActiveMacIfAvailable(
        stackUserID: String?,
        refreshBackupBeforeDial: Bool
    ) async -> Bool {
        true
    }

    func reconnectAllPairedMacs(
        stackUserID: String?,
        refreshBackupBeforeDial: Bool
    ) async -> Bool {
        true
    }

    func loadPairedMacs() async {}

    func createTerminal(in workspaceID: MobileWorkspacePreview.ID?) {
        createdTerminalWorkspaceIDs.append(workspaceID)
    }

    func renameWorkspace(
        id: MobileWorkspacePreview.ID,
        title: String,
        refreshAfterMutation: Bool
    ) async -> Result<Void, MobileWorkspaceMutationFailure> {
        .success(())
    }

    func removeComputer(
        representativeID: String,
        aliasIDs: [String]
    ) async -> MobileComputerRemovalResult {
        .removed
    }

    func removeComputerLocally(
        representativeID: String,
        aliasIDs: [String]
    ) async -> Bool {
        true
    }

    func terminalOutputRegistration(surfaceID: String) -> MobileTerminalOutputRegistration {
        outputRegistrationCountBySurfaceID[surfaceID, default: 0] += 1
        let registrationToken = UUID()
        let (stream, continuation) = AsyncStream<MobileTerminalOutputChunk>.makeStream()
        outputContinuations[registrationToken] = continuation
        return MobileTerminalOutputRegistration(
            registrationToken: registrationToken,
            stream: stream
        )
    }

    func terminalOutputDidProcess(surfaceID: String, streamToken: UUID) {}

    func terminalOutputDidUnmount(surfaceID: String, registrationToken: UUID) {
        outputContinuations.removeValue(forKey: registrationToken)?.finish()
    }

    func sendTerminalRawInput(_ data: Data, surfaceID: String) {}

    func requestTerminalVisibleScreenReplay(surfaceID: String) {}

    func prepareTerminalViewport(
        surfaceID: String,
        columns: Int,
        rows: Int
    ) -> MobileTerminalViewportPreparation? {
        preparedViewports.append(.init(
            surfaceID: surfaceID,
            columns: columns,
            rows: rows
        ))
        return nil
    }

    func updatePreparedTerminalViewport(
        _ preparation: MobileTerminalViewportPreparation
    ) async -> (
        columns: Int,
        rows: Int,
        renderEpoch: String?,
        renderRevisionFloor: UInt64?
    )? {
        nil
    }

    func updateTerminalViewport(
        surfaceID: String,
        columns: Int,
        rows: Int
    ) async -> (
        columns: Int,
        rows: Int,
        renderEpoch: String?,
        renderRevisionFloor: UInt64?
    )? {
        nil
    }
}
