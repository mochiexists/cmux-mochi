import CMUXMobileCore
import Foundation

/// How the Mobile section renders one route's verification state.
///
/// Kept next to the settings environment types (rather than inline in
/// ``MobileSection``) so the wording for each ``DiagnosticFailureKind`` lives in
/// one place and stays testable as a pure value mapping.
public extension CmxRouteReachability {
    /// Short trailing caption shown after the route's address.
    var settingsStatusText: String {
        switch self {
        case .unverified:
            return String(
                localized: "settings.mobile.routes.status.checking",
                defaultValue: "Checking…"
            )
        case let .verified(latencyMilliseconds):
            return String(
                localized: "settings.mobile.routes.status.reachable",
                defaultValue: "Reachable · \(latencyMilliseconds) ms"
            )
        case let .unreachable(kind):
            return Self.unreachableText(kind)
        }
    }

    /// SF Symbol paired with ``settingsStatusText``.
    var settingsStatusSystemImage: String {
        switch self {
        case .unverified:
            return "clock"
        case .verified:
            return "checkmark.circle.fill"
        case .unreachable:
            return "exclamationmark.triangle.fill"
        }
    }

    /// Whether the caption should be tinted as a warning. Only a *proven*
    /// failure warns: a still-pending probe stays neutral so an in-flight check
    /// never looks like a broken route.
    var settingsStatusIsWarning: Bool {
        if case .unreachable = self { return true }
        return false
    }

    /// Reason wording for each failure category the probe can produce. The
    /// wording names what the user can act on, not the transport error.
    private static func unreachableText(_ kind: DiagnosticFailureKind) -> String {
        switch kind {
        case .timedOut:
            return String(
                localized: "settings.mobile.routes.status.timedOut",
                defaultValue: "No answer — blocked or filtered"
            )
        case .connectionRefused:
            return String(
                localized: "settings.mobile.routes.status.refused",
                defaultValue: "Refused — nothing listening"
            )
        case .hostUnreachable, .offline, .noRoute:
            return String(
                localized: "settings.mobile.routes.status.unreachable",
                defaultValue: "No route to this address"
            )
        case .dnsFailed:
            return String(
                localized: "settings.mobile.routes.status.dnsFailed",
                defaultValue: "Name did not resolve"
            )
        case .permissionDenied:
            return String(
                localized: "settings.mobile.routes.status.permissionDenied",
                defaultValue: "Blocked by the system"
            )
        case .connectionClosed:
            return String(
                localized: "settings.mobile.routes.status.closed",
                defaultValue: "Closed before answering"
            )
        case .protocolViolation:
            return String(
                localized: "settings.mobile.routes.status.protocolViolation",
                defaultValue: "Answered, but not by cmux"
            )
        case .unsupportedRoute:
            return String(
                localized: "settings.mobile.routes.status.unsupported",
                defaultValue: "Cannot be checked from this Mac"
            )
        case .cancelled:
            return String(
                localized: "settings.mobile.routes.status.cancelled",
                defaultValue: "Check cancelled"
            )
        case .none, .secureChannelFailed, .credentialUnavailable, .policyUnavailable,
             .endpointUnavailable, .identityMismatch, .admissionDenied,
             .authorizationFailed, .accountMismatch, .superseded, .unknown:
            return String(
                localized: "settings.mobile.routes.status.unknown",
                defaultValue: "Not reachable"
            )
        }
    }
}
