import CMUXMobileCore
import CmuxMobileShell
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxHive

@MainActor
@Suite("Hive workspace coordinator")
struct HiveWorkspaceCoordinatorTests {
    @Test("pairs through the shell and exposes its remote workspaces")
    func pairsAndExposesWorkspaces() async throws {
        let workspace = MobileWorkspacePreview(
            id: "remote-workspace",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Mochi",
            terminals: [MobileTerminalPreview(id: "terminal-a", name: "Shell")]
        )
        let shell = HiveShellStub(
            pairingResult: .connected,
            workspaces: [workspace],
            isConnected: true
        )
        let coordinator = HiveWorkspaceCoordinator(shell: shell)

        let paired = await coordinator.pair(
            link: Self.deviceLinkURL
        )

        #expect(paired)
        #expect(coordinator.phase == .connected)
        #expect(coordinator.workspaces == [workspace])
        #expect(shell.receivedPairingLinks == [Self.deviceLinkURL])
    }

    @Test("reports a saved pairing as offline when its first dial fails")
    func reportsPairedOffline() async {
        let shell = HiveShellStub(
            pairingResult: .pairedOffline,
            workspaces: [],
            connectionError: "Connection refused",
            connectionErrorGuidance: "Open the remote app.",
            hasKnownPairing: true,
            isConnected: false
        )
        let coordinator = HiveWorkspaceCoordinator(shell: shell)

        let paired = await coordinator.pair(link: Self.deviceLinkURL)

        #expect(paired)
        #expect(coordinator.phase == .pairedOffline(
            message: "Connection refused",
            guidance: "Open the remote app."
        ))
    }

    @Test("does not attempt reconnect before any Mac has been paired")
    func skipsReconnectWithoutPairing() async {
        let shell = HiveShellStub(pairingResult: .failed, workspaces: [])
        let coordinator = HiveWorkspaceCoordinator(shell: shell)

        #expect(await !coordinator.reconnect())
        #expect(coordinator.phase == .idle)
        #expect(shell.reconnectCount == 0)
    }

    @Test("reports a known paired Mac as offline when reconnect fails")
    func reportsReconnectAsPairedOffline() async {
        let shell = HiveShellStub(
            pairingResult: .failed,
            workspaces: [],
            connectionError: "Connection refused",
            connectionErrorGuidance: "Open the remote app.",
            hasKnownPairing: true,
            isConnected: false
        )
        let coordinator = HiveWorkspaceCoordinator(shell: shell)

        #expect(await !coordinator.reconnect())
        #expect(coordinator.phase == .pairedOffline(
            message: "Connection refused",
            guidance: "Open the remote app."
        ))
    }

    @Test("reconnects every paired Mac instead of only the active Mac")
    func reconnectsEveryPairedMac() async {
        let pairedMacs = [
            Self.pairedMac(deviceID: "mac-a", displayName: "Studio", isActive: true),
            Self.pairedMac(deviceID: "mac-b", displayName: "Laptop", isActive: false),
        ]
        let shell = HiveShellStub(
            pairingResult: .failed,
            workspaces: [],
            hasKnownPairing: true,
            isConnected: true,
            pairedMacs: pairedMacs
        )
        let coordinator = HiveWorkspaceCoordinator(shell: shell)

        #expect(await coordinator.reconnect())
        #expect(shell.reconnectedPairingIDs == pairedMacs.map(\.id))
    }

    @Test("owns reconnect and snapshot polling without the browser window")
    func ownsConnectionLifecycle() async {
        let updatedWorkspace = MobileWorkspacePreview(
            id: "remote-workspace",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Updated",
            terminals: []
        )
        let shell = HiveShellStub(
            pairingResult: .failed,
            workspaces: [],
            hasKnownPairing: true,
            isConnected: true,
            pairedMacs: [Self.pairedMac(
                deviceID: "mac-a",
                displayName: "Studio",
                isActive: true
            )]
        )
        let coordinator = HiveWorkspaceCoordinator(
            shell: shell,
            lifecyclePollInterval: .zero
        )

        await coordinator.startConnectionLifecycle()
        shell.workspaces = [updatedWorkspace]
        await Self.yieldUntil {
            coordinator.workspaces == [updatedWorkspace]
        }
        coordinator.stopConnectionLifecycle()

        #expect(shell.reconnectedPairingIDs == shell.hivePairedMacs.map(\.id))
        #expect(coordinator.workspaces == [updatedWorkspace])
    }

    @Test("refresh projects reconnect and offline lifecycle truthfully")
    func refreshProjectsConnectionLifecycle() throws {
        let route = try CmxAttachRoute(
            id: "lan",
            kind: .localNetwork,
            endpoint: .hostPort(host: "studio-mac.local", port: 39_939),
            priority: 5
        )
        let shell = HiveShellStub(
            pairingResult: .failed,
            workspaces: [],
            hasKnownPairing: true,
            isConnected: true,
            activeRoute: route
        )
        let coordinator = HiveWorkspaceCoordinator(shell: shell)

        coordinator.refreshWorkspaceSnapshot()
        #expect(coordinator.phase == .connected)
        #expect(coordinator.connectionDetail?.contains("studio-mac.local:39939") == true)

        shell.isHiveMacConnected = false
        shell.hiveConnectionState = .disconnected
        shell.hiveMacConnectionStatus = .reconnecting
        shell.hiveIsReconnecting = true
        coordinator.refreshWorkspaceSnapshot()
        #expect(coordinator.phase == .connecting)

        shell.hiveMacConnectionStatus = .unavailable
        shell.hiveIsReconnecting = false
        coordinator.refreshWorkspaceSnapshot()
        guard case .pairedOffline = coordinator.phase else {
            Issue.record("Expected paired-offline phase")
            return
        }
    }

    @Test("remove exposes local-only confirmation then deletes exact pairing")
    func removesPairingLocallyAfterConfirmation() async {
        let mac = MobilePairedMac(
            macDeviceID: "mac-a",
            displayName: "Studio",
            routes: [],
            createdAt: Date(),
            lastSeenAt: Date(),
            isActive: true,
            stackUserID: nil,
            instanceTag: "nightly"
        )
        let shell = HiveShellStub(
            pairingResult: .failed,
            workspaces: [],
            hasKnownPairing: true,
            pairedMacs: [mac],
            removalResult: .requiresLocalOnlyConfirmation
        )
        let coordinator = HiveWorkspaceCoordinator(shell: shell)

        #expect(await coordinator.removePairing(mac) == .requiresLocalOnlyConfirmation)
        #expect(await coordinator.removePairing(mac, localOnly: true) == .removed)
        #expect(shell.localRemovalIDs == [mac.id])
    }

    @Test("routes supported workspace mutations through the mobile host RPCs")
    func routesWorkspaceMutations() async {
        let workspace = MobileWorkspacePreview(
            id: "remote-workspace",
            macDeviceID: "mac-a",
            macDisplayName: "Studio",
            name: "Remote",
            terminals: []
        )
        let shell = HiveShellStub(pairingResult: .connected, workspaces: [workspace])
        let coordinator = HiveWorkspaceCoordinator(shell: shell)

        coordinator.createTerminal(in: workspace.rpcWorkspaceID)
        let result = await coordinator.renameWorkspace(
            id: workspace.rpcWorkspaceID,
            title: "Renamed"
        )

        #expect(shell.createdTerminalWorkspaceIDs == [workspace.rpcWorkspaceID])
        #expect(shell.workspaceRenameRequests == [
            .init(id: workspace.rpcWorkspaceID, title: "Renamed", refreshAfterMutation: true),
        ])
        guard case .success = result else {
            Issue.record("Expected successful workspace rename")
            return
        }
    }

    private static let deviceLinkURL =
        "cmux-ios-dev://attach?v=3&r=192.168.1.25:3939"
        + "&f=" + String(repeating: "ab", count: 32)
        + "&t=single-use-ticket&n=Studio"

    private static func pairedMac(
        deviceID: String,
        displayName: String,
        isActive: Bool
    ) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: deviceID,
            displayName: displayName,
            routes: [],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 2),
            isActive: isActive,
            stackUserID: nil,
            instanceTag: "nightly"
        )
    }

    private static func yieldUntil(
        _ condition: @MainActor () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("condition never became true", sourceLocation: sourceLocation)
    }
}

@MainActor
private final class HiveShellStub: HiveShellServing {
    let pairingResult: MobilePairingURLConnectionResult
    var workspaces: [MobileWorkspacePreview]
    var connectionError: String?
    var connectionErrorGuidance: String?
    var hasKnownHivePairing: Bool
    var isHiveMacConnected: Bool
    var hiveConnectionState: MobileConnectionState
    var hiveMacConnectionStatus: MobileMacConnectionStatus
    var hiveIsReconnecting: Bool
    var hiveActiveRoute: CmxAttachRoute?
    var hivePairedMacs: [MobilePairedMac]
    var removalResult: MobileComputerRemovalResult
    private(set) var receivedPairingLinks: [String] = []
    private(set) var reconnectCount = 0
    private(set) var reconnectedPairingIDs: [String] = []
    private(set) var localRemovalIDs: [String] = []
    private(set) var createdTerminalWorkspaceIDs: [MobileWorkspacePreview.ID?] = []
    private(set) var workspaceRenameRequests: [WorkspaceRenameRequest] = []

    struct WorkspaceRenameRequest: Equatable {
        let id: MobileWorkspacePreview.ID
        let title: String
        let refreshAfterMutation: Bool
    }

    init(
        pairingResult: MobilePairingURLConnectionResult,
        workspaces: [MobileWorkspacePreview],
        connectionError: String? = nil,
        connectionErrorGuidance: String? = nil,
        hasKnownPairing: Bool = false,
        isConnected: Bool = false,
        activeRoute: CmxAttachRoute? = nil,
        pairedMacs: [MobilePairedMac] = [],
        removalResult: MobileComputerRemovalResult = .removed
    ) {
        self.pairingResult = pairingResult
        self.workspaces = workspaces
        self.connectionError = connectionError
        self.connectionErrorGuidance = connectionErrorGuidance
        self.hasKnownHivePairing = hasKnownPairing
        self.isHiveMacConnected = isConnected
        hiveConnectionState = isConnected ? .connected : .disconnected
        hiveMacConnectionStatus = isConnected ? .connected : .unavailable
        hiveIsReconnecting = false
        hiveActiveRoute = activeRoute
        hivePairedMacs = pairedMacs
        self.removalResult = removalResult
    }

    func connectPairingURLResult(
        _ rawValue: String?
    ) async -> MobilePairingURLConnectionResult {
        receivedPairingLinks.append(rawValue ?? "")
        return pairingResult
    }

    func reconnectActiveMacIfAvailable(
        stackUserID: String?,
        refreshBackupBeforeDial: Bool
    ) async -> Bool {
        reconnectCount += 1
        return isHiveMacConnected
    }

    func reconnectAllPairedMacs(
        stackUserID: String?,
        refreshBackupBeforeDial: Bool
    ) async -> Bool {
        reconnectedPairingIDs = hivePairedMacs.map(\.id)
        return isHiveMacConnected
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
        workspaceRenameRequests.append(.init(
            id: id,
            title: title,
            refreshAfterMutation: refreshAfterMutation
        ))
        return .success(())
    }

    func removeComputer(
        representativeID: String,
        aliasIDs: [String]
    ) async -> MobileComputerRemovalResult {
        removalResult
    }

    func removeComputerLocally(
        representativeID: String,
        aliasIDs: [String]
    ) async -> Bool {
        localRemovalIDs.append(representativeID)
        hivePairedMacs.removeAll { $0.id == representativeID }
        hasKnownHivePairing = !hivePairedMacs.isEmpty
        return true
    }
}
