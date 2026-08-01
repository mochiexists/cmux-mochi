import CMUXMobileCore
import Foundation

/// Verifies the Mac's advertised pairing routes by dialing them, so the
/// Settings "Reachable at" list reports an earned fact instead of a claim
/// derived from interface enumeration.
///
/// Probing is strictly **on demand**: the settings section asks when it shows
/// the route list and when the user hits refresh. There is deliberately no
/// background poll — an idle Settings window must not keep opening connections
/// to the listener.
///
/// The probe seam is injected (``MobileHostRouteProbing``), so tests substitute
/// outcomes without a socket:
///
/// ```swift
/// let service = MobileRouteReachabilityService(probe: StubRouteProbe(...))
/// let states = await service.verify(routes: routes)
/// ```
actor MobileRouteReachabilityService {
    /// Default deadline for one route. Long enough for a tailnet round trip,
    /// short enough that a firewalled address resolves while the user is still
    /// looking at the pane.
    static let defaultTimeoutNanoseconds: UInt64 = 3 * 1_000_000_000

    private let probe: any MobileHostRouteProbing
    private let timeoutNanoseconds: UInt64

    /// Route key → the in-flight probe for it. A second `verify` for a route
    /// already being dialed joins the running task instead of opening another
    /// connection, so an appearance racing a refresh tap costs one dial.
    private var inFlight: [String: Task<CmxRouteReachability, Never>] = [:]

    /// Creates a reachability service.
    ///
    /// - Parameters:
    ///   - probe: The dialing seam. Defaults to the real
    ///     `mobile.host.status` probe.
    ///   - timeoutNanoseconds: Per-route deadline.
    init(
        probe: any MobileHostRouteProbing = MobileHostStatusRouteProbe(),
        timeoutNanoseconds: UInt64 = MobileRouteReachabilityService.defaultTimeoutNanoseconds
    ) {
        self.probe = probe
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    /// Dial every supplied route concurrently and report what each one proved.
    ///
    /// Never throws and never returns ``CmxRouteReachability/unverified``: a
    /// route that cannot be dialed comes back as
    /// ``CmxRouteReachability/unreachable(_:)`` so a failure downgrades the
    /// display and nothing else. The listener is untouched either way — this
    /// only opens and closes ordinary client connections.
    ///
    /// - Parameter routes: The advertised routes to verify.
    /// - Returns: Reachability keyed by ``CmxAttachRoute/id``. Duplicated ids
    ///   collapse to one entry, matching how the UI lists them.
    func verify(routes: [CmxAttachRoute]) async -> [String: CmxRouteReachability] {
        guard !routes.isEmpty else { return [:] }
        // Start every dial before awaiting any of them, so a slow route does not
        // serialize the pass behind itself.
        var pending: [(route: CmxAttachRoute, task: Task<CmxRouteReachability, Never>)] = []
        pending.reserveCapacity(routes.count)
        for route in routes {
            pending.append((route, probeTask(for: route)))
        }

        var states: [String: CmxRouteReachability] = [:]
        states.reserveCapacity(pending.count)
        for entry in pending {
            states[entry.route.id] = await entry.task.value
            // Retire the finished dial here rather than from a detached cleanup
            // task: a pass must never hand a later refresh a completed result,
            // which would silently turn the refresh control into a replay.
            clearInFlight(key: Self.probeKey(for: entry.route), task: entry.task)
        }
        return states
    }

    /// The in-flight probe for `route`, starting one if none is running.
    private func probeTask(for route: CmxAttachRoute) -> Task<CmxRouteReachability, Never> {
        let key = Self.probeKey(for: route)
        if let existing = inFlight[key] {
            return existing
        }
        let seam = probe
        let timeout = timeoutNanoseconds
        let task = Task<CmxRouteReachability, Never> {
            await seam.probe(route, timeoutNanoseconds: timeout)
        }
        inFlight[key] = task
        return task
    }

    /// Drops a finished probe, unless a newer one already replaced it.
    private func clearInFlight(key: String, task: Task<CmxRouteReachability, Never>) {
        guard inFlight[key] == task else { return }
        inFlight.removeValue(forKey: key)
    }

    /// Identity for coalescing. Includes the endpoint, not just the route id, so
    /// a rebind that keeps the id but changes the port cannot reuse the probe
    /// that is still dialing the old one.
    private static func probeKey(for route: CmxAttachRoute) -> String {
        switch route.endpoint {
        case let .hostPort(host, port):
            return "\(route.id)|\(host)|\(port)"
        default:
            return "\(route.id)|\(route.kind.rawValue)"
        }
    }
}
