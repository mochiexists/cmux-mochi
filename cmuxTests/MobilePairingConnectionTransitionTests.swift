import CMUXMobileCore
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@MainActor
@Suite("Mobile pairing connection transition")
struct MobilePairingConnectionTransitionTests {
    private func makeReady() -> MobilePairingModel.Ready {
        MobilePairingModel.Ready(
            attachURL: "cmux-ios://pair?v=3&r=100.64.0.1:7777",
            tailscaleLines: ["100.64.0.1:7777"]
        )
    }

    @Test("A phone attaching above the baseline flips a displayed ticket to connected")
    func readyFlipsToConnectedOnAttach() {
        let ready = makeReady()
        let next = MobilePairingModel.connectionTransition(
            from: .ready(ready),
            activeConnectionCount: 1,
            baselineConnectionCount: 0
        )
        #expect(next == .connected(ready))
    }

    @Test("A ready ticket with no new connections stays in the waiting state")
    func readyStaysReadyWithoutConnections() {
        let ready = makeReady()
        let next = MobilePairingModel.connectionTransition(
            from: .ready(ready),
            activeConnectionCount: 0,
            baselineConnectionCount: 0
        )
        #expect(next == .ready(ready))
    }

    @Test("Pairing an additional device: an already-connected phone does not flip the new QR")
    func additionalDeviceStaysReadyUntilNewConnectionAboveBaseline() {
        let ready = makeReady()
        // One phone already attached when the QR is shown (baseline 1). The same
        // count must keep showing the QR so a second device can still pair.
        let stillWaiting = MobilePairingModel.connectionTransition(
            from: .ready(ready),
            activeConnectionCount: 1,
            baselineConnectionCount: 1
        )
        #expect(stillWaiting == .ready(ready))
        // A second device attaches (count rises above the baseline) -> connected.
        let connected = MobilePairingModel.connectionTransition(
            from: .ready(ready),
            activeConnectionCount: 2,
            baselineConnectionCount: 1
        )
        #expect(connected == .connected(ready))
    }

    @Test("Connected flips back to ready when the new connection drops to the baseline")
    func connectedFlipsBackToReadyWhenConnectionsDrop() {
        let ready = makeReady()
        let next = MobilePairingModel.connectionTransition(
            from: .connected(ready),
            activeConnectionCount: 1,
            baselineConnectionCount: 1
        )
        #expect(next == .ready(ready))
    }

    @Test("Connected stays connected while the new phone remains attached")
    func connectedStaysConnectedWithActiveConnections() {
        let ready = makeReady()
        let next = MobilePairingModel.connectionTransition(
            from: .connected(ready),
            activeConnectionCount: 2,
            baselineConnectionCount: 1
        )
        #expect(next == .connected(ready))
    }

    @Test("Preparing is unaffected by connection-count changes")
    func preparingIsUnaffected() {
        let next = MobilePairingModel.connectionTransition(
            from: .preparing,
            activeConnectionCount: 1,
            baselineConnectionCount: 0
        )
        #expect(next == .preparing)
    }

    @Test("A mixed route set selects only the Tailscale DeviceLink endpoint")
    func mixedRouteSetSelectsOnlyTailscale() throws {
        let routes = try [
            irohRoute(),
            tailscaleRoute(),
        ]
        let plan = try #require(MobilePairingModel.PairingRoutePlan.make(routes: routes))

        #expect(plan.tailscaleLines == ["100.64.0.1:7777"])
    }

    @Test("A Tailscale route produces the DeviceLink route plan")
    func tailscaleRouteProducesPlan() throws {
        let routes = try [tailscaleRoute()]
        let plan = try #require(MobilePairingModel.PairingRoutePlan.make(routes: routes))

        #expect(plan.tailscaleLines == ["100.64.0.1:7777"])
    }

    @Test("Iroh alone cannot produce a DeviceLink route plan")
    func irohAloneIsUnavailable() throws {
        let routes = try [irohRoute()]
        #expect(MobilePairingModel.PairingRoutePlan.make(
            routes: routes
        ) == nil)
    }

    @Test("Loopback alone never produces a physical-device QR")
    func loopbackAloneIsUnavailable() throws {
        let loopback = try CmxAttachRoute(
            id: "debug",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 7777)
        )
        #expect(MobilePairingModel.PairingRoutePlan.make(routes: [loopback]) == nil)
    }

    private func irohRoute() throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)),
                pathHints: []
            )
        )
    }

    private func tailscaleRoute() throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.1", port: 7777)
        )
    }
}
