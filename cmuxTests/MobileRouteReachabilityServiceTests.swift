import CMUXMobileCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Substituted probe seam: hands back a scripted outcome per route id and
/// records how many dials each route received, so a test can assert both the
/// reported state and that probing did not storm the listener.
private actor ScriptedRouteProbe: MobileHostRouteProbing {
    private let outcomes: [String: CmxRouteReachability]
    private let fallback: CmxRouteReachability
    private let holdUntilReleased: Bool
    private var dialCounts: [String: Int] = [:]
    private var gate: [CheckedContinuation<Void, Never>] = []

    init(
        outcomes: [String: CmxRouteReachability],
        fallback: CmxRouteReachability = .unreachable(.unknown),
        holdUntilReleased: Bool = false
    ) {
        self.outcomes = outcomes
        self.fallback = fallback
        self.holdUntilReleased = holdUntilReleased
    }

    nonisolated func probe(
        _ route: CmxAttachRoute,
        timeoutNanoseconds: UInt64
    ) async -> CmxRouteReachability {
        await record(route.id)
        if holdUntilReleased {
            await withCheckedContinuation { continuation in
                Task { await self.hold(continuation) }
            }
        }
        return outcomes[route.id] ?? fallback
    }

    func dialCount(for routeID: String) -> Int {
        dialCounts[routeID] ?? 0
    }

    /// Lets every held probe finish.
    func release() {
        let waiters = gate
        gate.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Whether every expected dial has arrived and is parked at the gate.
    func heldCount() -> Int { gate.count }

    private func record(_ routeID: String) {
        dialCounts[routeID, default: 0] += 1
    }

    private func hold(_ continuation: CheckedContinuation<Void, Never>) {
        gate.append(continuation)
    }
}

private func testRoute(
    id: String,
    kind: CmxAttachTransportKind = .tailscale,
    host: String = "100.64.0.1",
    port: Int = 58_465
) throws -> CmxAttachRoute {
    try CmxAttachRoute(
        id: id,
        kind: kind,
        endpoint: .hostPort(host: host, port: port),
        priority: 10
    )
}

@Suite struct MobileRouteReachabilityServiceTests {
    @Test func verifiedRouteReportsMeasuredLatency() async throws {
        let route = try testRoute(id: "tailscale")
        let service = MobileRouteReachabilityService(
            probe: ScriptedRouteProbe(outcomes: ["tailscale": .verified(latencyMilliseconds: 7)])
        )

        let states = await service.verify(routes: [route])

        #expect(states["tailscale"] == .verified(latencyMilliseconds: 7))
        #expect(states["tailscale"]?.isVerified == true)
        #expect(states["tailscale"]?.failureKind == nil)
    }

    @Test func unreachableRouteReportsClassifiedReason() async throws {
        let route = try testRoute(id: "tailscale")
        let service = MobileRouteReachabilityService(
            probe: ScriptedRouteProbe(outcomes: ["tailscale": .unreachable(.hostUnreachable)])
        )

        let states = await service.verify(routes: [route])

        #expect(states["tailscale"] == .unreachable(.hostUnreachable))
        #expect(states["tailscale"]?.isVerified == false)
        #expect(states["tailscale"]?.failureKind == .hostUnreachable)
    }

    @Test func timedOutRouteIsNotReportedAsReachable() async throws {
        let route = try testRoute(id: "tailscale")
        let service = MobileRouteReachabilityService(
            probe: ScriptedRouteProbe(outcomes: ["tailscale": .unreachable(.timedOut)])
        )

        let states = await service.verify(routes: [route])

        #expect(states["tailscale"]?.failureKind == .timedOut)
        #expect(states["tailscale"]?.isVerified == false)
    }

    /// The gap this whole feature closes: the listener really is bound and
    /// running, and the route really is advertised, yet a peer cannot open the
    /// port. Reachability must follow the probe, not the listener's own
    /// liveness.
    @Test func routeBlockedWhileListenerRunsReportsUnreachable() async throws {
        let route = try testRoute(id: "tailscale")
        let status = MobileHostServiceStatus(
            isRunning: true,
            port: 58_465,
            configuredPort: 58_465,
            routes: [route],
            activeConnectionCount: 0,
            lastErrorDescription: nil
        )
        let service = MobileRouteReachabilityService(
            probe: ScriptedRouteProbe(outcomes: ["tailscale": .unreachable(.timedOut)])
        )

        let states = await service.verify(routes: status.routes)

        #expect(status.isRunning)
        #expect(states["tailscale"] == .unreachable(.timedOut))
        #expect(states["tailscale"]?.isVerified == false)
    }

    @Test func mixedRouteSetKeepsEachRouteIndependent() async throws {
        let routes = [
            try testRoute(id: "tailscale", host: "100.64.0.1"),
            try testRoute(id: "tailscale_2", host: "100.64.0.2"),
            try testRoute(id: "debug_loopback", kind: .debugLoopback, host: "127.0.0.1"),
        ]
        let service = MobileRouteReachabilityService(
            probe: ScriptedRouteProbe(outcomes: [
                "tailscale": .verified(latencyMilliseconds: 3),
                "tailscale_2": .unreachable(.connectionRefused),
                "debug_loopback": .verified(latencyMilliseconds: 0),
            ])
        )

        let states = await service.verify(routes: routes)

        #expect(states.count == 3)
        #expect(states["tailscale"] == .verified(latencyMilliseconds: 3))
        #expect(states["tailscale_2"] == .unreachable(.connectionRefused))
        #expect(states["debug_loopback"] == .verified(latencyMilliseconds: 0))
    }

    @Test func emptyRouteListSkipsProbingEntirely() async throws {
        let probe = ScriptedRouteProbe(outcomes: [:])
        let service = MobileRouteReachabilityService(probe: probe)

        let states = await service.verify(routes: [])

        #expect(states.isEmpty)
        #expect(await probe.dialCount(for: "tailscale") == 0)
    }

    /// A pass never reports ``CmxRouteReachability/unverified``: that is the
    /// UI's pre-probe state, so a probe result must always be a decision.
    @Test func probeResultIsNeverUnverified() async throws {
        let route = try testRoute(id: "tailscale")
        let service = MobileRouteReachabilityService(
            probe: ScriptedRouteProbe(outcomes: [:], fallback: .unreachable(.unknown))
        )

        let states = await service.verify(routes: [route])

        #expect(states["tailscale"] != .unverified)
    }

    /// Routes are dialed concurrently, not one after another: every dial in a
    /// pass parks at the gate before any of them is released. A serial
    /// implementation could never park all three at once, so this hangs (and
    /// fails) rather than passing by luck.
    @Test func routesAreProbedConcurrently() async throws {
        let routes = [
            try testRoute(id: "a", host: "100.64.0.1"),
            try testRoute(id: "b", host: "100.64.0.2"),
            try testRoute(id: "c", host: "100.64.0.3"),
        ]
        let probe = ScriptedRouteProbe(
            outcomes: [
                "a": .verified(latencyMilliseconds: 1),
                "b": .unreachable(.timedOut),
                "c": .verified(latencyMilliseconds: 2),
            ],
            holdUntilReleased: true
        )
        let service = MobileRouteReachabilityService(probe: probe)

        async let pass = service.verify(routes: routes)
        while await probe.heldCount() < 3 {
            await Task.yield()
        }
        await probe.release()
        let states = await pass

        #expect(states["a"] == .verified(latencyMilliseconds: 1))
        #expect(states["b"] == .unreachable(.timedOut))
        #expect(states["c"] == .verified(latencyMilliseconds: 2))
    }

    /// A verdict is never cached across passes: the refresh control exists to
    /// re-earn the claim, so a second pass must dial again rather than replay
    /// the previous answer.
    @Test func repeatedVerificationDialsAgain() async throws {
        let route = try testRoute(id: "tailscale")
        let probe = ScriptedRouteProbe(
            outcomes: ["tailscale": .verified(latencyMilliseconds: 4)]
        )
        let service = MobileRouteReachabilityService(probe: probe)

        _ = await service.verify(routes: [route])
        _ = await service.verify(routes: [route])

        #expect(await probe.dialCount(for: "tailscale") == 2)
    }
}
