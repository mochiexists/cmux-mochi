import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport

/// The user-facing state rendered by the terminal connection pill.
enum MobileMacConnectionStatusPillPresentation: Equatable {
    case route(CmxAttachTransportKind)
    case reconnecting
    case unavailable

    /// Resolves connection state and the active route into honest terminal chrome.
    static func resolve(
        status: MobileMacConnectionStatus,
        routeKind: CmxAttachTransportKind?
    ) -> Self? {
        switch status {
        case .reconnecting:
            return .reconnecting
        case .unavailable:
            return .unavailable
        case .connected:
            switch routeKind {
            case .localNetwork:
                return .route(.localNetwork)
            case .tailscale:
                return .route(.tailscale)
            case .iroh, .websocket, .debugLoopback, nil:
                return nil
            }
        }
    }

    var label: String {
        switch self {
        case .route(.localNetwork):
            return L10n.string("mobile.connection.route.lan", defaultValue: "LAN")
        case .route(.tailscale):
            return L10n.string("mobile.connection.route.tailscale", defaultValue: "Tailscale")
        case .route:
            return MobileMacConnectionStatus.connected.label
        case .reconnecting:
            return MobileMacConnectionStatus.reconnecting.label
        case .unavailable:
            return MobileMacConnectionStatus.unavailable.label
        }
    }
}
