public import CmuxMobileShell
public import CmuxMobileShellModel

/// The narrow shell capability Hive needs from the shared mobile engine.
///
/// This keeps the macOS product layer testable while the production adapter
/// delegates the difficult connection, replay, and multi-Mac state machines to
/// ``MobileShellComposite``.
@MainActor
public protocol HiveShellServing: AnyObject {
    var workspaces: [MobileWorkspacePreview] { get }
    var connectionError: String? { get }
    var connectionErrorGuidance: String? { get }
    var hasKnownHivePairing: Bool { get }
    var isHiveMacConnected: Bool { get }

    func connectPairingURLResult(
        _ rawValue: String?
    ) async -> MobilePairingURLConnectionResult

    func reconnectActiveMacIfAvailable(
        stackUserID: String?,
        refreshBackupBeforeDial: Bool
    ) async -> Bool
}

extension MobileShellComposite: HiveShellServing {
    public var hasKnownHivePairing: Bool { hasKnownPairedMac }
    public var isHiveMacConnected: Bool { connectionState == .connected }
}
