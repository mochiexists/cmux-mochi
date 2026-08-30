import CmuxMobileShellModel

enum MobileAuthenticatedShellPresentation: Equatable {
    case disconnected
    case workspace

    static func resolve(
        connectionState: MobileConnectionState,
        hasKnownPairedMac: Bool,
        hasHiddenComputers: Bool
    ) -> Self {
        if connectionState != .connected,
           !hasKnownPairedMac,
           !hasHiddenComputers {
            return .disconnected
        }
        return .workspace
    }
}

/// Keeps a mounted workspace shell stable while preventing stale chat or
/// terminal navigation during an active Mac reconnection attempt.
enum MobileReconnectPresentation {
    static func shouldBlockWorkspaceNavigation(
        connectionState: MobileConnectionState,
        isReconnectingStoredMac: Bool,
        isMacSwitchInFlight: Bool
    ) -> Bool {
        connectionState != .connected
            && (isReconnectingStoredMac || isMacSwitchInFlight)
    }
}
