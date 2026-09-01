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
            workspaces: [workspace]
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
    private(set) var receivedPairingLinks: [String] = []

    init(
        pairingResult: MobilePairingURLConnectionResult,
        workspaces: [MobileWorkspacePreview],
        connectionError: String? = nil,
        connectionErrorGuidance: String? = nil
    ) {
        self.pairingResult = pairingResult
        self.workspaces = workspaces
        self.connectionError = connectionError
        self.connectionErrorGuidance = connectionErrorGuidance
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
        pairingResult.didConnect
    }
}
