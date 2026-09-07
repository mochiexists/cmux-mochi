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

    private static let deviceLinkURL =
        "cmux-ios-dev://attach?v=3&r=192.168.1.25:3939"
        + "&f=" + String(repeating: "ab", count: 32)
        + "&t=single-use-ticket&n=Studio"
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
    private(set) var localRemovalIDs: [String] = []

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

    func loadPairedMacs() async {}

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
