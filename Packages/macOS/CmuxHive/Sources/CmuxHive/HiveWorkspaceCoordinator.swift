public import CmuxMobileShellModel
public import Observation

/// Mac-facing adapter over the shared MobileShell connection engine.
@MainActor
@Observable
public final class HiveWorkspaceCoordinator {
    /// User-visible state for pairing and reconnect surfaces.
    public enum Phase: Equatable, Sendable {
        case idle
        case pairing
        case connecting
        case connected
        case pairedOffline(message: String, guidance: String?)
        case failed(message: String, guidance: String?)
    }

    public private(set) var phase: Phase = .idle
    /// Latest immutable workspace projection from the shared shell engine.
    public private(set) var workspaces: [MobileWorkspacePreview]
    public var hasKnownPairing: Bool { shell.hasKnownHivePairing }

    @ObservationIgnored private let shell: any HiveShellServing
    @ObservationIgnored private let pairingLinkDecoder: HivePairingLinkDecoder

    public init(
        shell: any HiveShellServing,
        pairingLinkDecoder: HivePairingLinkDecoder = HivePairingLinkDecoder()
    ) {
        self.shell = shell
        self.pairingLinkDecoder = pairingLinkDecoder
        workspaces = shell.workspaces
    }

    /// Create a renderer adapter for one terminal exposed by the shell.
    public func makeTerminalSession(surfaceID: String) -> HiveTerminalSession? {
        guard let terminalShell = shell as? any HiveTerminalShellServing else {
            return nil
        }
        return HiveTerminalSession(surfaceID: surfaceID, shell: terminalShell)
    }

    /// Pair using the host's DeviceLink v3 URL and expose the shell result.
    @discardableResult
    public func pair(link: String) async -> Bool {
        do {
            _ = try pairingLinkDecoder.decode(link)
        } catch {
            phase = .failed(
                message: "This is not a current Mochi pairing link.",
                guidance: "Open Pair a Device on the remote Mac and paste its new link."
            )
            return false
        }

        phase = .pairing
        let result = await shell.connectPairingURLResult(link)
        guard result.didConnect else {
            phase = .failed(
                message: shell.connectionError ?? "Could not pair with the remote Mac.",
                guidance: shell.connectionErrorGuidance
            )
            return false
        }
        refreshWorkspaceSnapshot()
        if shell.isHiveMacConnected {
            phase = .connected
        } else {
            phase = .pairedOffline(
                message: shell.connectionError ?? "Pairing saved; the remote Mac is offline.",
                guidance: shell.connectionErrorGuidance ?? "Open Mochi on the remote Mac, then retry."
            )
        }
        return true
    }

    /// Reconnect the last active DeviceLink pairing from local storage.
    @discardableResult
    public func reconnect() async -> Bool {
        guard hasKnownPairing else {
            phase = .idle
            return false
        }
        phase = .connecting
        let connected = await shell.reconnectActiveMacIfAvailable(
            stackUserID: nil,
            refreshBackupBeforeDial: false
        )
        if connected {
            refreshWorkspaceSnapshot()
            phase = .connected
        } else {
            phase = .failed(
                message: shell.connectionError ?? "The remote Mac is offline.",
                guidance: shell.connectionErrorGuidance
            )
        }
        return connected
    }

    /// Refreshes the UI snapshot after background shell state changes.
    public func refreshWorkspaceSnapshot() {
        let latest = shell.workspaces
        if workspaces != latest {
            workspaces = latest
        }
    }
}
