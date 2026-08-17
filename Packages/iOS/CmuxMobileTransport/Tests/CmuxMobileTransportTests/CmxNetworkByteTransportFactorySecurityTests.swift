import CMUXMobileCore
import Network
import Testing
@testable import CmuxMobileTransport

private enum RejectingTailscaleAuthorityError: Error {
    case rejected
}

private actor RejectingTailscaleAuthority: CmxTailscaleRouteAuthorizing {
    private(set) var preparationCount = 0

    func prepare(
        request _: CmxByteTransportRequest
    ) throws -> CmxPreparedTailscaleRoute {
        preparationCount += 1
        throw RejectingTailscaleAuthorityError.rejected
    }

    func validate(
        proof _: CmxTailscaleRouteProof,
        connectionPath _: NWPath
    ) throws {
        throw RejectingTailscaleAuthorityError.rejected
    }
}

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

    @Test func preparesExactGrandfatheredTailscaleGrantAtConnectBoundary() async throws {
        let request = try legacyTailscaleRequest()
        let authority = RejectingTailscaleAuthority()
        let factory = CmxNetworkByteTransportFactory(
            tailscaleRouteAuthority: authority
        )

        let transport = try factory.makeTransport(for: request)
        #expect(transport is CmxPreparingTailscaleByteTransport)
        #expect(await authority.preparationCount == 0)

        await #expect(throws: CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable) {
            try await transport.connect()
        }
        #expect(await authority.preparationCount == 1)
    }

    @Test func rejectsEveryGrandfatheredGrantSubstitutionBeforeDial() throws {
        let validRequest = try legacyTailscaleRequest()
        let validEvidence = try CmxLegacyTailscaleAuthorizationEvidence(
            macDeviceID: "mac-1",
            host: "100.71.210.41",
            port: 58_465
        )
        let factory = CmxNetworkByteTransportFactory()

        let deviceSubstitution = CmxByteTransportRequest(
            route: validRequest.route,
            expectedPeerDeviceID: "mac-2",
            authorizationMode: .legacyTailscaleBearer(validEvidence)
        )
        #expect(throws: CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable) {
            _ = try factory.makeTransport(for: deviceSubstitution)
        }

        let hostSubstitution = CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: "tailscale",
                kind: .tailscale,
                endpoint: .hostPort(host: "100.71.210.42", port: 58_465)
            ),
            expectedPeerDeviceID: "mac-1",
            authorizationMode: .legacyTailscaleBearer(validEvidence)
        )
        #expect(throws: CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable) {
            _ = try factory.makeTransport(for: hostSubstitution)
        }

        let portSubstitution = CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: "tailscale",
                kind: .tailscale,
                endpoint: .hostPort(host: "100.71.210.41", port: 58_466)
            ),
            expectedPeerDeviceID: "mac-1",
            authorizationMode: .legacyTailscaleBearer(validEvidence)
        )
        #expect(throws: CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable) {
            _ = try factory.makeTransport(for: portSubstitution)
        }
    }

    @Test func buildsUserAuthorizedPairingTransportForItsExactDestination() throws {
        // The pairing window's tokenless v1 compatibility code carries a
        // self-reported Mac identity, the bare-route v2 grammar carries none.
        // The authorization anchors on the destination, so both dial.
        for expectedPeerDeviceID in [nil, "", "mac-1"] {
            let request = try userAuthorizedPairingRequest(
                expectedPeerDeviceID: expectedPeerDeviceID
            )
            let transport = try CmxNetworkByteTransportFactory()
                .makeTransport(for: request)
            #expect(transport is CmxPreparingTailscaleByteTransport)
        }
    }

    @Test func rejectsUserAuthorizedPairingDestinationSubstitution() throws {
        let authorization = try CmxUserTailscalePairingAuthorization(
            host: "100.71.210.41",
            port: 58_465
        )
        let factory = CmxNetworkByteTransportFactory()

        let hostSubstitution = CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: "tailscale",
                kind: .tailscale,
                endpoint: .hostPort(host: "100.71.210.42", port: 58_465)
            ),
            expectedPeerDeviceID: "",
            authorizationMode: .userAuthorizedTailscalePairing(authorization)
        )
        #expect(throws: CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable) {
            _ = try factory.makeTransport(for: hostSubstitution)
        }

        let portSubstitution = CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: "tailscale",
                kind: .tailscale,
                endpoint: .hostPort(host: "100.71.210.41", port: 58_466)
            ),
            expectedPeerDeviceID: "",
            authorizationMode: .userAuthorizedTailscalePairing(authorization)
        )
        #expect(throws: CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable) {
            _ = try factory.makeTransport(for: portSubstitution)
        }
    }
}

private func userAuthorizedPairingRequest(
    expectedPeerDeviceID: String?
) throws -> CmxByteTransportRequest {
    let host = "100.71.210.41"
    let port = 58_465
    return CmxByteTransportRequest(
        route: try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port)
        ),
        expectedPeerDeviceID: expectedPeerDeviceID,
        authorizationMode: .userAuthorizedTailscalePairing(
            try CmxUserTailscalePairingAuthorization(host: host, port: port)
        )
    )
}

private func legacyTailscaleRequest() throws -> CmxByteTransportRequest {
    let host = "100.71.210.41"
    let port = 58_465
    return CmxByteTransportRequest(
        route: try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port)
        ),
        expectedPeerDeviceID: "mac-1",
        authorizationMode: .legacyTailscaleBearer(
            try CmxLegacyTailscaleAuthorizationEvidence(
                macDeviceID: "mac-1",
                host: host,
                port: port
            )
        )
    )
}

// MARK: - DeviceLink admission

/// A DeviceLink pairing admits itself through the mutual-TLS handshake: this
/// device's key against the Mac's pinned fingerprint. That is stronger evidence
/// than the bearer grants beside it, so `.transportAdmission` is accepted on the
/// routes a paired device actually dials — but only when there is an identity to
/// offer, which is what keeps the fork's TLS-only listener reachable without
/// weakening anything for a build that holds no pairing.
@Test func acceptsTransportAdmissionWhenADeviceLinkIdentityExists() throws {
    let factory = CmxNetworkByteTransportFactory(
        supportedKinds: [.debugLoopback, .tailscale],
        deviceLinkTLSOptions: { NWProtocolTLS.Options() }
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
        deviceLinkTLSOptions: { nil }
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
