import CMUXMobileCore
import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileShellRouteAuthPolicyTests {
    @Test func normalizesBareHostsAndRejectsURLSyntax() {
        #expect(MobileShellRouteAuthPolicy.normalizedHost("  mac.local  ") == "mac.local")
        #expect(MobileShellRouteAuthPolicy.normalizedHost("[fd00::1]") == "fd00::1")
        #expect(MobileShellRouteAuthPolicy.normalizedHost("https://mac.local") == nil)
        #expect(MobileShellRouteAuthPolicy.normalizedHost("mac.local/path") == nil)
        #expect(MobileShellRouteAuthPolicy.normalizedHost("mac local") == nil)
    }

    @Test func routeIsLoopbackOnlyForLoopbackHostPortEndpoints() throws {
        let loopbackIP = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1")
        let localhost = try hostPortRoute(kind: .debugLoopback, host: "localhost")
        let ipv6Loopback = try hostPortRoute(kind: .debugLoopback, host: "::1")
        let loopbackOnNetworkKind = try hostPortRoute(kind: .tailscale, host: "127.0.0.1")
        let pretendLoopback = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.attacker.example"
        )
        let networkIP = try hostPortRoute(kind: .tailscale, host: "100.71.210.41")
        let irohPeer = try CmxAttachRoute(
            id: CmxAttachTransportKind.iroh.rawValue,
            kind: .iroh,
            endpoint: .peer(
                id: String(repeating: "f", count: 64),
                relayHint: nil,
                directAddrs: [],
                relayURL: nil
            )
        )

        #expect(MobileShellRouteAuthPolicy.routeIsLoopback(loopbackIP))
        #expect(MobileShellRouteAuthPolicy.routeIsLoopback(localhost))
        #expect(MobileShellRouteAuthPolicy.routeIsLoopback(ipv6Loopback))
        #expect(MobileShellRouteAuthPolicy.routeIsLoopback(loopbackOnNetworkKind))
        #expect(!MobileShellRouteAuthPolicy.routeIsLoopback(pretendLoopback))
        #expect(!MobileShellRouteAuthPolicy.routeIsLoopback(networkIP))
        #expect(!MobileShellRouteAuthPolicy.routeIsLoopback(irohPeer))
    }

    private func hostPortRoute(
        kind: CmxAttachTransportKind,
        host: String
    ) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: kind.rawValue,
            kind: kind,
            endpoint: .hostPort(
                host: host,
                port: CmxMobileDefaults.defaultHostPort
            )
        )
    }
}
