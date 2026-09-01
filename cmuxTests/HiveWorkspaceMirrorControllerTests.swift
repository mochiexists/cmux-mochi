import CmuxHive
import CmuxMobileShell
import CmuxMobileShellModel
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
}

@MainActor
private final class HiveWorkspaceMirrorShellStub: HiveShellServing, HiveTerminalShellServing {
    var workspaces: [MobileWorkspacePreview]
    var connectionError: String?
    var connectionErrorGuidance: String?
    var hasKnownHivePairing = true
    var isHiveMacConnected = true
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

    func terminalOutputRegistration(surfaceID: String) -> MobileTerminalOutputRegistration {
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
        nil
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
