import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileTransport

@Test func pingRequiresAuthenticationForLoopbackRoute() async throws {
    let route = try CmxAttachRoute(
        id: "loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 49_831)
    )

    let result = await CmxNetworkRoutePinger().ping(route, timeoutNanoseconds: 5_000_000_000)

    #expect(result == .authenticationRequired)
}

@Test func pingReportsUnsupportedRouteForNonHostPortEndpoint() async throws {
    let route = try CmxAttachRoute(
        id: "iroh",
        kind: .iroh,
        endpoint: .peer(
            id: String(repeating: "e", count: 64),
            relayHint: nil,
            directAddrs: [],
            relayURL: nil
        )
    )

    let result = await CmxNetworkRoutePinger().ping(route)

    #expect(result == .unsupportedRoute)
}

@Test func pingReportsAuthenticationRequiredForSecureLANRoute() async throws {
    let route = try CmxAttachRoute(
        id: "local-network",
        kind: .localNetwork,
        endpoint: .hostPort(host: "192.168.1.20", port: 49_831)
    )

    let result = await CmxNetworkRoutePinger().ping(route)

    #expect(result == .authenticationRequired)
}

@Test func pingRejectsPublicHostMislabeledAsSecureLAN() async throws {
    let route = try CmxAttachRoute(
        id: "public-as-local-network",
        kind: .localNetwork,
        endpoint: .hostPort(host: "203.0.113.10", port: 49_831)
    )

    let result = await CmxNetworkRoutePinger().ping(route)

    #expect(result == .unsupportedRoute)
}
