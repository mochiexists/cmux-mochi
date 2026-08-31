import CMUXMobileCore
import Network
import Synchronization
import Testing
@testable import CmuxMobileTransport

// MARK: - DeviceLink admission

/// A DeviceLink pairing admits itself through the mutual-TLS handshake: this
/// device's key against the Mac's pinned fingerprint. Transport admission is
/// accepted on the routes a paired device actually dials, but only when there is an identity to
/// offer, which is what keeps the fork's TLS-only listener reachable without
/// weakening anything for a build that holds no pairing.
@Test func acceptsTransportAdmissionWhenADeviceLinkIdentityExists() throws {
    let factory = CmxNetworkByteTransportFactory(
        supportedKinds: [.debugLoopback, .tailscale],
        deviceLinkTLSOptions: { _ in NWProtocolTLS.Options() }
    )

    let tailscale = try CmxAttachRoute(
        id: "tailscale",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.1.2", port: 49831)
    )
    _ = try factory.makeTransport(
        for: CmxByteTransportRequest(
            route: tailscale,
            expectedPeerDeviceID: "mac-1",
            authorizationMode: .transportAdmission
        )
    )

    let loopback = try CmxAttachRoute(
        id: "loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 49831)
    )
    _ = try factory.makeTransport(
        for: CmxByteTransportRequest(
            route: loopback,
            expectedPeerDeviceID: "mac-1",
            authorizationMode: .transportAdmission
        )
    )
}

/// Fail closed: without an identity there is no handshake to admit on, so the
/// same request must be refused rather than falling back to plaintext.
@Test func refusesTransportAdmissionWithoutADeviceLinkIdentity() throws {
    let factory = CmxNetworkByteTransportFactory(
        supportedKinds: [.debugLoopback, .tailscale],
        deviceLinkTLSOptions: { _ in nil }
    )

    for (id, kind, host) in [
        ("tailscale", CmxAttachTransportKind.tailscale, "100.64.1.2"),
        ("loopback", CmxAttachTransportKind.debugLoopback, "127.0.0.1"),
    ] {
        let route = try CmxAttachRoute(
            id: id,
            kind: kind,
            endpoint: .hostPort(host: host, port: 49831)
        )
        #expect(throws: CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable) {
            _ = try factory.makeTransport(
                for: CmxByteTransportRequest(
                    route: route,
                    expectedPeerDeviceID: "mac-1",
                    authorizationMode: .transportAdmission
                )
            )
        }
    }
}

/// A transport request owns one immutable admission decision. Reading the
/// credential source again after the fail-closed guard could turn a previously
/// authorized request into a plaintext transport when credentials are removed
/// or another connection changes the selected identity between reads.
@available(macOS 15, *)
@Test func resolvesDeviceLinkTLSOptionsOncePerRequest() throws {
    // The synchronous `@Sendable` resolver needs a tiny thread-safe counter;
    // it does not protect production or ongoing domain state.
    let resolutionCount = Mutex(0)
    let factory = CmxNetworkByteTransportFactory(
        supportedKinds: [.debugLoopback],
        deviceLinkTLSOptions: { _ in
            resolutionCount.withLock { count in
                count += 1
                return count == 1 ? NWProtocolTLS.Options() : nil
            }
        }
    )
    let route = try CmxAttachRoute(
        id: "loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 49_831)
    )

    _ = try factory.makeTransport(
        for: CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: "mac-1",
            authorizationMode: .transportAdmission
        )
    )

    #expect(resolutionCount.withLock { $0 } == 1)
}

/// Concurrent foreground and background dials must never consult mutable
/// process-wide target state. Each resolver invocation receives the immutable
/// Mac identity carried by the transport request that owns the dial.
@available(macOS 15, *)
@Test func resolvesDeviceLinkTLSOptionsForEachExactMacInstance() throws {
    let resolvedTargets = Mutex<[(String?, String?)]>([])
    let factory = CmxNetworkByteTransportFactory(
        supportedKinds: [.debugLoopback],
        deviceLinkTLSOptions: { request in
            resolvedTargets.withLock { targets in
                targets.append((
                    request.expectedPeerDeviceID,
                    request.expectedPeerInstanceTag
                ))
            }
            return NWProtocolTLS.Options()
        }
    )
    let route = try CmxAttachRoute(
        id: "loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 49_831)
    )

    for (macDeviceID, instanceTag) in [
        ("mac-stable", "stable"),
        ("mac-nightly", "nightly"),
    ] {
        _ = try factory.makeTransport(
            for: CmxByteTransportRequest(
                route: route,
                expectedPeerDeviceID: macDeviceID,
                expectedPeerInstanceTag: instanceTag,
                authorizationMode: .transportAdmission
            )
        )
    }

    let targets = resolvedTargets.withLock { $0 }
    #expect(targets.count == 2)
    #expect(targets[0].0 == "mac-stable")
    #expect(targets[0].1 == "stable")
    #expect(targets[1].0 == "mac-nightly")
    #expect(targets[1].1 == "nightly")
}

// MARK: - MagicDNS route resolution

private func magicDNSRequest(host: String) throws -> CmxByteTransportRequest {
    CmxByteTransportRequest(
        route: try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: 49831)
        ),
        expectedPeerDeviceID: "mac-1",
        authorizationMode: .transportAdmission
    )
}

/// The Mac publishes a MagicDNS name because it is the only locator that
/// survives a tailnet IP change, but the route proof requires a numeric peer.
/// Resolving it here is what keeps that durable route dialable; without this it
/// is the one route that can never be used, which stays invisible until the
/// numeric routes beside it go stale.
@Test func resolvesMagicDNSRouteToItsTailnetAddress() async throws {
    let resolved = try await CmxPreparingTailscaleByteTransport.requestResolvingMagicDNS(
        magicDNSRequest(host: "work-mac.tailnet.ts.net"),
        resolveHost: { _ in ["100.112.69.84", "fd7a:115c:a1e0::e53a:4555"] }
    )
    #expect(resolved.route.endpoint == .hostPort(host: "100.112.69.84", port: 49831))
    // Everything else about the request must survive the rewrite.
    #expect(resolved.route.kind == .tailscale)
    #expect(resolved.expectedPeerDeviceID == "mac-1")
    #expect(resolved.authorizationMode == .transportAdmission)
}

/// A numeric route is already provable and must not be re-resolved.
@Test func leavesNumericRoutesUntouched() async throws {
    let request = try magicDNSRequest(host: "100.112.69.84")
    let resolved = try await CmxPreparingTailscaleByteTransport.requestResolvingMagicDNS(
        request,
        resolveHost: { _ in
            Issue.record("a numeric peer must not be resolved")
            return []
        }
    )
    #expect(resolved == request)
}

/// Fail closed: a name that resolves outside the tailnet is not a peer this
/// transport may dial, and must not be rewritten into one.
@Test func refusesNamesResolvingOutsideTheTailnet() async throws {
    await #expect(throws: CmxTailscaleRouteProofError.nonNumericPeer) {
        _ = try await CmxPreparingTailscaleByteTransport.requestResolvingMagicDNS(
            magicDNSRequest(host: "evil.example.com"),
            resolveHost: { _ in ["93.184.216.34", "10.0.0.5"] }
        )
    }
    // A name that resolves to nothing is the same answer.
    await #expect(throws: CmxTailscaleRouteProofError.nonNumericPeer) {
        _ = try await CmxPreparingTailscaleByteTransport.requestResolvingMagicDNS(
            magicDNSRequest(host: "missing.tailnet.ts.net"),
            resolveHost: { _ in [] }
        )
    }
}
