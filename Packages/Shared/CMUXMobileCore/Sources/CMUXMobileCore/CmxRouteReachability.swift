/// Whether an advertised route has been *proven* usable by an actual dial, as
/// opposed to merely having been derived from local interface enumeration.
///
/// The Mac advertises routes by enumerating its own interfaces (Tailscale CGNAT
/// / ULA addresses plus reverse-DNS MagicDNS names). That enumeration answers
/// "which addresses does this Mac hold?", not "can a peer open the pairing port
/// on them?" — a stale address, a rebound listener, or a local firewall rule all
/// leave the enumerated route looking healthy. This type carries the outcome of
/// a real connect-back so the UI can separate a claim from a verified fact.
///
/// Lives in the core package so both the probing side (the Mac host service) and
/// the display side (the settings UI package) can name the same states without
/// either depending on the other.
public enum CmxRouteReachability: Sendable, Equatable {
    /// No probe result is available yet: the route is advertised but unproven.
    ///
    /// This is a display state only — a probe never *returns* it. It covers the
    /// window between the route list appearing and the first probe completing,
    /// and it is deliberately distinct from ``unreachable(_:)`` so a pending
    /// probe is never rendered as a failure.
    case unverified

    /// A dial to this route's host and port reached the Mac's pairing listener
    /// and it answered. Carries the round-trip latency in whole milliseconds.
    case verified(latencyMilliseconds: Int)

    /// The dial did not reach an answering listener, classified with the shared
    /// ``DiagnosticFailureKind`` vocabulary (for example
    /// ``DiagnosticFailureKind/timedOut`` for a firewall that drops the SYN,
    /// ``DiagnosticFailureKind/connectionRefused`` when nothing holds the port,
    /// or ``DiagnosticFailureKind/hostUnreachable`` when the address is stale).
    case unreachable(DiagnosticFailureKind)

    /// Whether a real dial proved this route usable.
    ///
    /// `false` for ``unverified`` as well as ``unreachable(_:)``: an unproven
    /// route must never read as a reachable one, which is the whole point of
    /// probing.
    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    /// The classified reason this route failed, or `nil` when it is
    /// ``verified(latencyMilliseconds:)`` or still ``unverified``.
    public var failureKind: DiagnosticFailureKind? {
        if case let .unreachable(kind) = self { return kind }
        return nil
    }
}
