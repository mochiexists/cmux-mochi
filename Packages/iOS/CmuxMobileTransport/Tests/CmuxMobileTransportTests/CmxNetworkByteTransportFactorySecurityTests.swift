import CMUXMobileCore
import Testing
@testable import CmuxMobileTransport

@Suite struct CmxTransportFactorySecurityTests {
    @Test func buildsLoopbackTransportWithExplicitAuthorizationIntent() throws {
        let route = try CmxAttachRoute(
            id: "loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 49831)
        )
        let request = CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: "mac-1",
            authorizationMode: .stackBearer
        )

        let transport = try CmxNetworkByteTransportFactory().makeTransport(for: request)

        #expect(transport is CmxNetworkByteTransport)
    }

    @Test func rejectsTailscaleRouteWithoutAuthorizationIntent() throws {
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.1.2", port: 49831)
        )

        #expect(throws: (any Error).self) {
            _ = try CmxNetworkByteTransportFactory().makeTransport(for: route)
        }
        #expect(throws: CmxNetworkByteTransportError.authorizationIntentRequired) {
            _ = try CmxNetworkByteTransport(route: route)
        }
    }

    @Test func rejectsRouteKindAuthorizationSubstitution() throws {
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.1.2", port: 49831)
        )
        let request = CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: "mac-1",
            authorizationMode: .transportAdmission
        )

        #expect(throws: (any Error).self) {
            _ = try CmxNetworkByteTransportFactory().makeTransport(for: request)
        }
    }

    @Test func rejectsMagicDNSBeforeDial() throws {
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "work-mac.tailnet.ts.net", port: 49831)
        )
        let request = CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: "mac-1",
            authorizationMode: .stackBearer
        )

        #expect(throws: (any Error).self) {
            _ = try CmxNetworkByteTransportFactory().makeTransport(for: request)
        }
    }

    @Test func rejectsTailscaleBearerWhenOnlyPacketTunnelHeuristicsAreAvailable() async throws {
        let route = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.1.2", port: 49831)
        )
        let request = CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: "mac-1",
            authorizationMode: .stackBearer
        )
        let factory = CmxNetworkByteTransportFactory()

        #expect(throws: CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable) {
            _ = try factory.makeTransport(for: request)
        }
    }

    /// A DeviceLink dial to loopback must fail rather than go out in plaintext.
    ///
    /// The pairing host is TLS-only on every interface, so a plaintext socket
    /// is left hanging and reported as a connect timeout — which reads as "the
    /// Mac is unreachable" and sent an earlier investigation after the network
    /// instead of the missing identity.
    @Test func rejectsDeviceLinkLoopbackDialWithoutTLSOptions() throws {
        let route = try CmxAttachRoute(
            id: "loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 49831)
        )
        let request = CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: "mac-1",
            authorizationMode: .transportAdmission
        )
        // No `deviceLinkTLSOptions`: the identity is missing or unreadable.
        let factory = CmxNetworkByteTransportFactory()

        #expect(throws: CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable) {
            _ = try factory.makeTransport(for: request)
        }
    }

    /// The plaintext UI-test mock host keeps working: it is a genuinely
    /// plaintext loopback peer, and it dials as `.stackBearer`.
    @Test func allowsPlaintextLoopbackForTheMockHost() throws {
        let route = try CmxAttachRoute(
            id: "loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 49831)
        )
        let request = CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: "mac-1",
            authorizationMode: .stackBearer
        )

        let transport = try CmxNetworkByteTransportFactory().makeTransport(for: request)

        #expect(transport is CmxNetworkByteTransport)
    }
}
