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
        case failed(message: String, guidance: String?)
    }

    public private(set) var phase: Phase = .idle

    @ObservationIgnored private let shell: any HiveShellServing
    @ObservationIgnored private let pairingLinkDecoder: HivePairingLinkDecoder

    /// Current remote workspace snapshots, including owning Mac identity/tag.
    public var workspaces: [MobileWorkspacePreview] { shell.workspaces }

    public init(
        shell: any HiveShellServing,
        pairingLinkDecoder: HivePairingLinkDecoder = HivePairingLinkDecoder()
    ) {
        self.shell = shell
        self.pairingLinkDecoder = pairingLinkDecoder
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
        phase = .connected
        return true
    }

    /// Reconnect the last active DeviceLink pairing from local storage.
    @discardableResult
    public func reconnect() async -> Bool {
        phase = .connecting
        let connected = await shell.reconnectActiveMacIfAvailable(
            stackUserID: nil,
            refreshBackupBeforeDial: false
        )
        if connected {
            phase = .connected
        } else {
            phase = .failed(
                message: shell.connectionError ?? "The remote Mac is offline.",
                guidance: shell.connectionErrorGuidance
            )
        }
        return connected
    }
}
