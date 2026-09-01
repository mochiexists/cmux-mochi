import CmuxMobileShell
import CmuxMobileShellModel
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
            pairingResult: .connected,
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
    private(set) var receivedPairingLinks: [String] = []
    private(set) var reconnectCount = 0

    init(
        pairingResult: MobilePairingURLConnectionResult,
        workspaces: [MobileWorkspacePreview],
        connectionError: String? = nil,
        connectionErrorGuidance: String? = nil,
        hasKnownPairing: Bool = false,
        isConnected: Bool = false
    ) {
        self.pairingResult = pairingResult
        self.workspaces = workspaces
        self.connectionError = connectionError
        self.connectionErrorGuidance = connectionErrorGuidance
        self.hasKnownHivePairing = hasKnownPairing
        self.isHiveMacConnected = isConnected
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
}
