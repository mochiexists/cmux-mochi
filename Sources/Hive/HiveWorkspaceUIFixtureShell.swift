#if DEBUG
import CMUXMobileCore
import CmuxHive
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation

/// Deterministic, keychain-free Hive state used only by tagged screenshot builds.
@MainActor
final class HiveWorkspaceUIFixtureShell: HiveShellServing, HiveTerminalShellServing {
    static let environmentKey = "CMUX_E2E_HIVE_UI_FIXTURE"
    static let pairingLink =
        "cmux-ios-dev://attach?v=3&r=127.0.0.1:3939"
        + "&f=" + String(repeating: "ab", count: 32)
        + "&t=fixture-ticket&n=Studio"

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
    var hiveMacConnectionStatuses: [String: MobileMacConnectionStatus]

    let fixtureName: String

    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let fixtureName = environment[Self.environmentKey],
              !fixtureName.isEmpty else { return nil }
        self.fixtureName = fixtureName

        let mac = MobilePairedMac(
            macDeviceID: "fixture-studio",
            displayName: "Studio Mac",
            routes: [],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 2),
            isActive: true,
            stackUserID: nil,
            instanceTag: "nightly"
        )
        let status: MobileMacConnectionStatus = switch fixtureName {
        case "workspace-connected", "workspace-connected-mounted", "pane-connected", "no-workspaces":
            .connected
        case "workspace-reconnecting", "pane-reconnecting":
            .reconnecting
        default: .unavailable
        }
        let hasPairing = fixtureName != "never-paired" && fixtureName != "pairing"
        let includesWorkspace = fixtureName.hasPrefix("workspace-")
            || fixtureName.hasPrefix("pane-")

        hivePairedMacs = hasPairing ? [mac] : []
        hasKnownHivePairing = hasPairing
        hiveMacConnectionStatuses = hasPairing ? [mac.id: status] : [:]
        hiveMacConnectionStatus = status
        isHiveMacConnected = status == .connected
        hiveConnectionState = status == .connected ? .connected : .disconnected
        hiveIsReconnecting = status == .reconnecting
        connectionError = status == .unavailable && hasPairing
            ? String(localized: "hive.error.offline", defaultValue: "The remote Mac is offline.")
            : nil
        connectionErrorGuidance = status == .unavailable && hasPairing
            ? String(localized: "hive.offline.guidance", defaultValue: "Open Mochi on the remote Mac, then retry.")
            : nil
        hiveActiveRoute = nil

        if includesWorkspace {
            var workspace = MobileWorkspacePreview(
                id: "fixture-workspace",
                macDeviceID: mac.macDeviceID,
                macDisplayName: mac.resolvedName,
                name: "Mochi Nightly",
                terminals: [
                    MobileTerminalPreview(id: "fixture-terminal", name: "Build logs"),
                    MobileTerminalPreview(
                        id: "fixture-starting",
                        name: "Starting terminal",
                        isReady: false
                    ),
                ]
            )
            workspace.macInstanceTag = mac.instanceTag
            workspace.macConnectionStatus = status
            workspaces = [workspace]
        } else {
            workspaces = []
        }
    }

    func connectPairingURLResult(
        _ rawValue: String?
    ) async -> MobilePairingURLConnectionResult {
        if fixtureName == "pairing" {
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                return .failed
            }
        }
        return .connected
    }

    func reconnectActiveMacIfAvailable(
        stackUserID: String?,
        refreshBackupBeforeDial: Bool
    ) async -> Bool {
        isHiveMacConnected
    }

    func reconnectAllPairedMacs(
        stackUserID: String?,
        refreshBackupBeforeDial: Bool,
        attemptDeadlineNanoseconds: UInt64?
    ) async -> Bool {
        isHiveMacConnected
    }

    func reconnectHiveMac(macDeviceID: String, instanceTag: String?) async {}
    func loadPairedMacs() async {}
    func createTerminal(in workspaceID: MobileWorkspacePreview.ID?) {}

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

    func terminalOutputRegistration(
        surfaceID: String
    ) -> MobileTerminalOutputRegistration {
        let (stream, _) = AsyncStream<MobileTerminalOutputChunk>.makeStream()
        return MobileTerminalOutputRegistration(
            registrationToken: UUID(),
            stream: stream
        )
    }

    func terminalOutputDidProcess(surfaceID: String, streamToken: UUID) {}
    func terminalOutputDidUnmount(surfaceID: String, registrationToken: UUID) {}
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
#endif
