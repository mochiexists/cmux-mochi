public import CmuxMobileShellModel

/// Pure authentication-gating policy for the mobile root scene.
///
/// Combines optional Stack auth and durable DeviceLink identity into the
/// booleans the root scene branches on. Transport admission is deliberately
/// absent: DeviceLink owns it per Mac and per app instance.
public struct MobileRootAuthGate {
    private init() {}

    /// Whether the root may show the authenticated shell. A Stack account can
    /// unlock account services, while a DeviceLink key can unlock its paired
    /// Macs; neither is converted into transport authority for the other.
    public static func isAuthenticated(
        stackAuthenticated: Bool,
        pairedDeviceAuthenticated: Bool = false
    ) -> Bool {
        stackAuthenticated || pairedDeviceAuthenticated
    }

    /// Whether a previously stored Mac should be reconnected automatically.
    ///
    /// Fork (cmux Mochi): an account is no longer the only way to hold a
    /// durable credential. A device paired through DeviceLink holds a private
    /// key and the Mac's pin, which is exactly as good a reason to reconnect as
    /// a Stack session — this is the gate that used to make account-free
    /// pairings unable to survive a cold launch.
    ///
    /// DeviceLink is the only transport credential. Stack authentication may
    /// keep account-backed services alive, but it never authorizes a socket or
    /// starts a stored-Mac dial.
    public static func shouldReconnectStoredMac(
        hasPairedDeviceIdentity: Bool,
        isRestoringSession: Bool,
        connectionState: MobileConnectionState
    ) -> Bool {
        hasPairedDeviceIdentity && !isRestoringSession
            && connectionState != .connected
    }

    /// Whether the restoring-session UI should be shown while reconnecting a known
    /// paired Mac.
    ///
    /// A returning user (already authenticated, previously paired) should see the
    /// existing "Restoring session…" state during the reconnect window instead of
    /// the empty add-device sheet. A genuinely never-paired user still falls
    /// through to add-device immediately. The persisted ``hasKnownPairedMac`` hint
    /// covers the very first rendered frame before the async paired-Mac read runs.
    /// ``pairedMacHintUndetermined`` covers installs that predate the hint (the key
    /// was never written but a Mac may already exist in the paired-Mac store): they
    /// are treated as "may have a paired Mac" until the first reconnect attempt
    /// resolves and writes the hint, so they do not flash add-device on the first
    /// launch after updating. ``didFinishStoredMacReconnectAttempt`` lets a failed or
    /// offline attempt fall through to the disconnected view instead of spinning.
    /// - Parameters:
    ///   - authenticated: Whether the user is authenticated (Stack or attach ticket).
    ///   - connectionState: The current connection state.
    ///   - isReconnectingStoredMac: Whether a found stored Mac is actively mid-reconnect.
    ///   - hasKnownPairedMac: The persisted hint that this device has paired a Mac before.
    ///   - pairedMacHintUndetermined: Whether the hint has never been written on this install (key absent).
    ///   - didFinishStoredMacReconnectAttempt: Whether the first launch reconnect attempt has resolved.
    /// - Returns: `true` while authenticated and the first stored-Mac reconnect
    ///   attempt has not resolved, provided a reconnect is active or a paired-Mac
    ///   hint indicates that restoration may be possible.
    public static func shouldShowRestoringStoredMac(
        authenticated: Bool,
        connectionState: MobileConnectionState,
        isReconnectingStoredMac: Bool,
        hasKnownPairedMac: Bool,
        pairedMacHintUndetermined: Bool,
        didFinishStoredMacReconnectAttempt: Bool
    ) -> Bool {
        guard authenticated, connectionState != .connected else { return false }
        guard !didFinishStoredMacReconnectAttempt else { return false }
        if isReconnectingStoredMac { return true }
        return hasKnownPairedMac || pairedMacHintUndetermined
    }

    /// Which shell surface the authenticated root scene mounts.
    ///
    /// The restoring window is data on the one workspace-shell surface, not a
    /// separate surface: mounting a different view while the stored-Mac
    /// reconnect resolved destroyed the shell's presentation state (a Settings
    /// sheet opened during the reconnect window dismissed itself the moment the
    /// reconnection finished, failed, or the startup gate expired).
    public enum MobileRootShellSurface: Equatable {
        /// The workspace shell (list + detail). `isRestoringStoredMac` marks
        /// the startup stored-Mac reconnect window and varies only the shell's
        /// loading inputs.
        case workspaceShell(isRestoringStoredMac: Bool)
        /// The terminal no-devices state: signed in with no saved Macs at all
        /// and no restoring window that could still produce one.
        case disconnectedNoKnownPairedMac
    }

    /// Selects the authenticated root scene's shell surface.
    /// - Parameters:
    ///   - connectionState: The current connection state.
    ///   - showRestoringStoredMac: Whether the startup reconnect window is
    ///     active (``shouldShowRestoringStoredMac(authenticated:connectionState:isReconnectingStoredMac:hasKnownPairedMac:pairedMacHintUndetermined:didFinishStoredMacReconnectAttempt:)``
    ///     combined with the caller's startup gates).
    ///   - showDisconnectedNoPairedMacShell: Whether the no-devices screen is
    ///     warranted at all. The caller resolves this from the shell
    ///     presentation policy (no saved Macs AND no hidden computers), so
    ///     hidden-computer semantics live in one place.
    /// - Returns: The surface to mount. Restoring, connected, and
    ///   offline-with-saved-Macs all return ``MobileRootShellSurface/workspaceShell(isRestoringStoredMac:)``
    ///   so the mounted shell view never changes identity across those
    ///   transitions.
    public static func shellSurface(
        connectionState: MobileConnectionState,
        showRestoringStoredMac: Bool,
        showDisconnectedNoPairedMacShell: Bool
    ) -> MobileRootShellSurface {
        let isRestoringStoredMac = connectionState != .connected && showRestoringStoredMac
        if connectionState != .connected, showDisconnectedNoPairedMacShell, !isRestoringStoredMac {
            return .disconnectedNoKnownPairedMac
        }
        return .workspaceShell(isRestoringStoredMac: isRestoringStoredMac)
    }
}
