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
    @Test("launch does not create Hive storage before any Mac is paired")
    func launchWithoutPairingLeavesHiveStorageUntouched() throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hive-lazy-\(UUID().uuidString)", isDirectory: true)
        let tag = "hive-lazy-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: stateDirectory)
            UserDefaults.standard.removePersistentDomain(forName: "dev.cmux.hive-e2e.\(tag)")
            unsetenv("CMUX_E2E_HIVE_STATE_DIR")
            unsetenv("CMUX_TAG")
        }
        setenv("CMUX_E2E_HIVE_STATE_DIR", stateDirectory.path, 1)
        setenv("CMUX_TAG", tag, 1)

        var service: HiveWorkspaceService? = HiveWorkspaceService()
        service?.start()

        #expect(
            try FileManager.default.contentsOfDirectory(atPath: stateDirectory.path).isEmpty,
            "launch should not create SQLite storage or the mobile shell without a pairing"
        )
        service = nil
    }

    @Test("launch with a persisted pairing hint creates Hive and starts reconnect")
    func launchWithPairingHintStartsReconnect() async throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hive-paired-\(UUID().uuidString)", isDirectory: true)
        let tag = "hive-paired-\(UUID().uuidString)"
        let suiteName = "dev.cmux.hive-e2e.\(tag)"
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: stateDirectory)
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            unsetenv("CMUX_E2E_HIVE_STATE_DIR")
            unsetenv("CMUX_TAG")
        }
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: "cmux.mobile.hasKnownPairedMac")
        setenv("CMUX_E2E_HIVE_STATE_DIR", stateDirectory.path, 1)
        setenv("CMUX_TAG", tag, 1)

        let service = HiveWorkspaceService()
        service.start()

        let composition = try #require(
            service.compositionForTesting,
            "launch with a pairing hint should create the Hive composition"
        )
        #expect(
            try !FileManager.default.contentsOfDirectory(atPath: stateDirectory.path).isEmpty,
            "launch with a pairing hint should open the Hive pairing store"
        )
        var reconnectStarted = false
        for _ in 0..<1_000 {
            reconnectStarted = composition.shell.isReconnectingStoredMac
                || composition.shell.didFinishStoredMacReconnectAttempt
            if reconnectStarted { break }
            await Task.yield()
        }
        #expect(reconnectStarted, "launch with a pairing hint should start the stored-Mac reconnect")
        composition.coordinator.stopConnectionLifecycle()
    }

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

    @Test("sends viewport only for a changed grid or a reconnected Mac")
    func deduplicatesViewportUntilReconnect() throws {
        let terminal = MobileTerminalPreview(id: "surface-a", name: "Alpha")
        var remoteWorkspace = MobileWorkspacePreview(
            id: "remote-workspace",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Remote",
            terminals: [terminal]
        )
        remoteWorkspace.macInstanceTag = "dev-a"
        remoteWorkspace.macConnectionStatus = .connected
        let pairedMac = MobilePairedMac(
            macDeviceID: "mac-a",
            displayName: "Studio",
            routes: [],
            createdAt: .distantPast,
            lastSeenAt: .distantPast,
            isActive: true,
            stackUserID: nil,
            instanceTag: "dev-a"
        )
        let shell = HiveWorkspaceMirrorShellStub(workspaces: [remoteWorkspace])
        shell.hivePairedMacs = [pairedMac]
        shell.hiveMacConnectionStatuses = [pairedMac.id: .connected]
        let coordinator = HiveWorkspaceCoordinator(shell: shell)
        coordinator.refreshWorkspaceSnapshot(forcePhaseReconciliation: true)
        let controller = HiveWorkspaceMirrorController()
        let manager = TabManager()

        controller.open(
            workspace: remoteWorkspace,
            selectedTerminal: terminal,
            coordinator: coordinator,
            in: manager
        )
        let mirror = try #require(manager.tabs.first { $0.isHiveWorkspaceMirror })
        let panel = try #require(mirror.focusedTerminalPanel)
        let sample = Self.sizingSample(columns: 80, rows: 24)

        panel.surface.onManualSizeApplied?(sample)
        panel.surface.onManualSizeApplied?(sample)

        remoteWorkspace.macConnectionStatus = .unavailable
        shell.workspaces = [remoteWorkspace]
        shell.isHiveMacConnected = false
        shell.hiveConnectionState = .disconnected
        shell.hiveMacConnectionStatus = .unavailable
        shell.hiveMacConnectionStatuses = [pairedMac.id: .unavailable]
        coordinator.refreshWorkspaceSnapshot(forcePhaseReconciliation: true)
        controller.reconcileMirrors()

        remoteWorkspace.macConnectionStatus = .connected
        shell.workspaces = [remoteWorkspace]
        shell.isHiveMacConnected = true
        shell.hiveConnectionState = .connected
        shell.hiveMacConnectionStatus = .connected
        shell.hiveMacConnectionStatuses = [pairedMac.id: .connected]
        coordinator.refreshWorkspaceSnapshot(forcePhaseReconciliation: true)
        controller.reconcileMirrors()
        panel.surface.onManualSizeApplied?(sample)

        #expect(shell.preparedViewports == [
            .init(surfaceID: terminal.id.rawValue, columns: 80, rows: 24),
            .init(surfaceID: terminal.id.rawValue, columns: 80, rows: 24),
        ])
    }

    @Test("re-sends the viewport after input overflow stops output")
    func resumesOutputAfterInputOverflow() async throws {
        let terminal = MobileTerminalPreview(id: "surface-a", name: "Alpha")
        var remoteWorkspace = MobileWorkspacePreview(
            id: "remote-workspace",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Remote",
            terminals: [terminal]
        )
        remoteWorkspace.macInstanceTag = "dev-a"
        remoteWorkspace.macConnectionStatus = .connected
        let shell = HiveWorkspaceMirrorShellStub(workspaces: [remoteWorkspace])
        let coordinator = HiveWorkspaceCoordinator(shell: shell)
        let controller = HiveWorkspaceMirrorController(maximumPendingInputBytes: 1)
        let manager = TabManager()

        controller.open(
            workspace: remoteWorkspace,
            selectedTerminal: terminal,
            coordinator: coordinator,
            in: manager
        )
        let mirror = try #require(manager.tabs.first { $0.isHiveWorkspaceMirror })
        let panel = try #require(mirror.focusedTerminalPanel)
        panel.hostedView.setVisibleInUI(true)
        panel.hostedView.setActive(true)
        panel.hostedView.layoutSubtreeIfNeeded()
        await Self.waitForLiveSurface(panel.surface)
        let sample = try #require(panel.surface.rawSizingSample())
        panel.surface.onManualSizeApplied?(sample)
        shell.resetPreparedViewports()

        #expect(controller.forwardInput(
            .bytes(Data([0x61, 0x62])),
            to: panel.id
        ) == .overflow)
        await Task.yield()
        await Task.yield()
        controller.reconcileMirrors()

        #expect(shell.preparedViewports == [
            .init(
                surfaceID: terminal.id.rawValue,
                columns: sample.columns,
                rows: sample.rows
            ),
        ])
    }

    @Test("promotes the surviving resize owner after the original panel deallocates")
    func promotesResizeOwnerAfterPanelDeallocation() throws {
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
        var firstPanel: TerminalPanel? = try #require(firstMirror.terminalPanel(for: firstPanelID))
        weak var releasedFirstPanel = firstPanel
        let secondPanel = try #require(secondMirror.terminalPanel(for: secondPanelID))

        #expect(firstMirror.removeRemoteTmuxDisplayPane(firstPanelID))
        firstPanel = nil
        #expect(releasedFirstPanel == nil)
        controller.reconcileMirrors()
        secondPanel.surface.onManualSizeApplied?(Self.sizingSample(columns: 120, rows: 40))

        let attachment = try #require(controller.statusSnapshot().first {
            $0.remoteSurfaceID == terminal.id.rawValue
        })
        #expect(attachment.localMountCount == 1)
        #expect(shell.preparedViewports == [
            .init(surfaceID: terminal.id.rawValue, columns: 120, rows: 40),
        ])
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

    @Test("automation rejects an explicit surface that is not in the remote workspace")
    func automationRejectsUnknownSurface() {
        let terminal = MobileTerminalPreview(id: "surface-a", name: "Alpha")
        let remoteWorkspace = MobileWorkspacePreview(
            id: "remote-workspace",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Remote",
            terminals: [terminal]
        )
        let coordinator = HiveWorkspaceCoordinator(
            shell: HiveWorkspaceMirrorShellStub(workspaces: [remoteWorkspace])
        )
        let service = HiveWorkspaceService(coordinator: coordinator)
        let manager = TabManager()

        let opened = service.open(
            workspaceID: remoteWorkspace.id.rawValue,
            surfaceID: "missing-surface",
            in: manager
        )

        #expect(opened == nil)
        #expect(!manager.tabs.contains { $0.isHiveWorkspaceMirror })
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

    @Test("keeps a mounted remote pane visible with offline connection chrome")
    func presentsOfflineMountedPane() throws {
        let terminal = MobileTerminalPreview(id: "surface-a", name: "Alpha")
        var remoteWorkspace = MobileWorkspacePreview(
            id: "remote-workspace",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Remote",
            terminals: [terminal]
        )
        remoteWorkspace.macInstanceTag = "dev-a"
        remoteWorkspace.macConnectionStatus = .connected
        let pairedMac = MobilePairedMac(
            macDeviceID: "mac-a",
            displayName: "Studio",
            routes: [],
            createdAt: .distantPast,
            lastSeenAt: .distantPast,
            isActive: true,
            stackUserID: nil,
            instanceTag: "dev-a"
        )
        let shell = HiveWorkspaceMirrorShellStub(workspaces: [remoteWorkspace])
        shell.hivePairedMacs = [pairedMac]
        shell.hiveMacConnectionStatuses = [pairedMac.id: .connected]
        let coordinator = HiveWorkspaceCoordinator(shell: shell)
        coordinator.refreshWorkspaceSnapshot(forcePhaseReconciliation: true)
        let controller = HiveWorkspaceMirrorController()
        let manager = TabManager()

        controller.open(
            workspace: remoteWorkspace,
            selectedTerminal: terminal,
            coordinator: coordinator,
            in: manager
        )
        let mirror = try #require(manager.tabs.first { $0.isHiveWorkspaceMirror })
        let panel = try #require(mirror.focusedTerminalPanel)
        #expect(mirror.remoteConnectionState == .connected)
        #expect(panel.hiveConnectionState == .connected)

        shell.workspaces = []
        shell.isHiveMacConnected = false
        shell.hiveConnectionState = .disconnected
        shell.hiveMacConnectionStatus = .unavailable
        shell.hiveMacConnectionStatuses = [pairedMac.id: .unavailable]
        coordinator.refreshWorkspaceSnapshot(forcePhaseReconciliation: true)
        controller.reconcileMirrors()

        #expect(manager.tabs.contains { $0.id == mirror.id })
        #expect(mirror.remoteConnectionState == .disconnected)
        #expect(panel.hiveConnectionState == .disconnected)
    }

    @Test("removes an offline mirror after its exact Mac pairing is forgotten")
    func removesMirrorAfterPairingIsForgotten() throws {
        let terminal = MobileTerminalPreview(id: "surface-a", name: "Alpha")
        var remoteWorkspace = MobileWorkspacePreview(
            id: "remote-workspace",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Remote",
            terminals: [terminal]
        )
        remoteWorkspace.macInstanceTag = "dev-a"
        remoteWorkspace.macConnectionStatus = .connected
        let pairedMac = MobilePairedMac(
            macDeviceID: "mac-a",
            displayName: "Studio",
            routes: [],
            createdAt: .distantPast,
            lastSeenAt: .distantPast,
            isActive: true,
            stackUserID: nil,
            instanceTag: "dev-a"
        )
        let shell = HiveWorkspaceMirrorShellStub(workspaces: [remoteWorkspace])
        shell.hivePairedMacs = [pairedMac]
        shell.hiveMacConnectionStatuses = [pairedMac.id: .connected]
        let coordinator = HiveWorkspaceCoordinator(shell: shell)
        coordinator.refreshWorkspaceSnapshot(forcePhaseReconciliation: true)
        let controller = HiveWorkspaceMirrorController()
        let manager = TabManager()

        controller.open(
            workspace: remoteWorkspace,
            selectedTerminal: terminal,
            coordinator: coordinator,
            in: manager
        )
        let mirror = try #require(manager.tabs.first { $0.isHiveWorkspaceMirror })

        shell.workspaces = []
        shell.hivePairedMacs = []
        shell.hiveMacConnectionStatuses = [:]
        shell.hasKnownHivePairing = false
        shell.isHiveMacConnected = false
        shell.hiveConnectionState = .disconnected
        shell.hiveMacConnectionStatus = .unavailable
        coordinator.refreshWorkspaceSnapshot(forcePhaseReconciliation: true)
        controller.reconcileMirrors()

        #expect(!manager.tabs.contains { $0.id == mirror.id })
        #expect(controller.statusSnapshot().isEmpty)
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
        #expect(manager.tabs.first?.id != mirror.id)
        #expect(manager.tabs.first?.isRemoteTmuxMirror == false)
        #expect(manager.tabs.first?.panels.count == 1)
    }

    @Test("replaces the only workspace with a working local terminal when its remote workspace closes")
    func replacesOnlyWorkspaceAfterRemoteWorkspaceCloses() throws {
        let terminal = MobileTerminalPreview(id: "surface-a", name: "Alpha")
        var remoteWorkspace = MobileWorkspacePreview(
            id: "remote-workspace",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Remote",
            terminals: [terminal]
        )
        remoteWorkspace.macInstanceTag = "dev-a"
        remoteWorkspace.macConnectionStatus = .connected
        let pairedMac = MobilePairedMac(
            macDeviceID: "mac-a",
            displayName: "Studio",
            routes: [],
            createdAt: .distantPast,
            lastSeenAt: .distantPast,
            isActive: true,
            stackUserID: nil,
            instanceTag: "dev-a"
        )
        let shell = HiveWorkspaceMirrorShellStub(workspaces: [remoteWorkspace])
        shell.hivePairedMacs = [pairedMac]
        shell.hiveMacConnectionStatuses = [pairedMac.id: .connected]
        let coordinator = HiveWorkspaceCoordinator(shell: shell)
        coordinator.refreshWorkspaceSnapshot(forcePhaseReconciliation: true)
        let controller = HiveWorkspaceMirrorController()
        let manager = TabManager()

        controller.open(
            workspace: remoteWorkspace,
            selectedTerminal: terminal,
            coordinator: coordinator,
            in: manager
        )
        let mirror = try #require(manager.tabs.first { $0.isHiveWorkspaceMirror })
        for workspace in manager.tabs where workspace.id != mirror.id {
            manager.closeWorkspace(workspace, recordHistory: false)
        }
        let remotePanelID = try #require(mirror.focusedPanelId)

        shell.workspaces = []
        coordinator.refreshWorkspaceSnapshot(forcePhaseReconciliation: true)
        controller.reconcileMirrors()

        let replacement = try #require(manager.tabs.first)
        let replacementPanel = try #require(replacement.focusedTerminalPanel)
        #expect(manager.tabs.count == 1)
        #expect(replacement.id != mirror.id)
        #expect(replacementPanel.id != remotePanelID)
        #expect(!replacement.isRemoteTmuxMirror)
        #expect(replacementPanel.hiveConnectionState == nil)
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

    private static func waitForLiveSurface(_ surface: TerminalSurface) async {
        guard !surface.hasLiveSurface else { return }
        let previousOnRuntimeReady = surface.onRuntimeReady
        defer { surface.onRuntimeReady = previousOnRuntimeReady }
        let readiness = AsyncStream<Void> { continuation in
            surface.onRuntimeReady = {
                previousOnRuntimeReady?()
                continuation.yield()
                continuation.finish()
            }
        }
        for await _ in readiness { break }
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
    var hiveMacConnectionStatuses: [String: MobileMacConnectionStatus] = [:]
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
        refreshBackupBeforeDial: Bool,
        attemptDeadlineNanoseconds: UInt64?
    ) async -> Bool {
        true
    }

    func reconnectHiveMac(macDeviceID: String, instanceTag: String?) async {}

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

    func resetPreparedViewports() {
        preparedViewports.removeAll()
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
