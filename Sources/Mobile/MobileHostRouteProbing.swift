import CMUXMobileCore

/// Seam for verifying one advertised pairing route by dialing it the way a
/// paired phone would.
///
/// The Mac's "Reachable at" list is derived from `getifaddrs` + reverse DNS
/// (``MobileRouteResolver``), which proves only that the Mac *holds* those
/// addresses. This seam is what turns an advertised route into an earned claim.
/// It exists as a protocol so ``MobileRouteReachabilityService`` can be unit
/// tested against substituted outcomes (reachable / refused / timed out /
/// blocked-while-listening) without opening a socket, mirroring the
/// `CmxRoutePinging` seam the iOS side already uses.
protocol MobileHostRouteProbing: Sendable {
    /// Dial one route and report whether the Mac's pairing listener answered.
    ///
    /// Never throws: every outcome, including a malformed route, folds into a
    /// ``CmxRouteReachability``. Implementations must never return
    /// ``CmxRouteReachability/unverified`` — that is a display-only state.
    ///
    /// - Parameters:
    ///   - route: The advertised route to verify.
    ///   - timeoutNanoseconds: Deadline covering connect *and* reply.
    func probe(
        _ route: CmxAttachRoute,
        timeoutNanoseconds: UInt64
    ) async -> CmxRouteReachability
}
