import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

/// Fork (cmux Mochi): coverage for the account-free pairing path, where the
/// attach ticket is the whole credential.
///
/// Upstream refuses to build a transport for a `.tailscale` route because it
/// cannot prove a generic packet tunnel really is Tailscale, and a Stack bearer
/// sent over an impostor tunnel would leak an account credential. This fork
/// declares `.attachTicket` instead, which permits that route on the strict
/// condition that no account credential ever crosses it. These tests pin that
/// condition — it is the entire basis for relaxing the upstream gate.
@Suite struct MobileCoreRPCAttachTicketTransportTests {
    private func ticket(
        authToken: String?,
        route: CmxAttachRoute,
        expiresAt: Date? = Date().addingTimeInterval(600)
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-1",
            macDisplayName: "Studio",
            routes: [route],
            expiresAt: expiresAt,
            authToken: authToken
        )
    }

    private func makeClient(
        route: CmxAttachRoute,
        ticket: CmxAttachTicket,
        capture: TransportRequestCapture,
        transport: QueuedCancellationProbeTransport
    ) -> MobileCoreRPCClient {
        let runtime = TestMobileSyncRuntime(
            transportFactory: IntentRecordingTransportFactory(
                transport: transport,
                capture: capture
            ),
            stackAccessTokenForStatus: "status-token",
            rpcRequestTimeoutNanoseconds: 200_000_000
        )
        return MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
    }

    /// A ticket-bearing Tailscale connection must declare `.attachTicket`, which
    /// is what `CmxNetworkByteTransportFactory` keys on to allow the route at all.
    @Test func tailscaleRouteWithAttachTokenDeclaresAttachTicketMode() async throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let capture = TransportRequestCapture()
        let client = makeClient(
            route: route,
            ticket: try ticket(authToken: "ticket-secret", route: route),
            capture: capture,
            transport: QueuedCancellationProbeTransport()
        )

        _ = try? await client.sendRequest(
            try MobileCoreRPCClient.requestData(method: "mobile.host.status")
        )

        #expect(capture.request()?.authorizationMode == .attachTicket)
    }

    /// Scoping matters: `debugLoopback` is already trusted for Stack bearers, and
    /// tickets there legitimately top up with an account token. Declaring
    /// `.attachTicket` for it would break that, so the mode must stay Tailscale-only.
    @Test func loopbackRouteWithAttachTokenKeepsStackBearerMode() async throws {
        let route = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 58465)
        let capture = TransportRequestCapture()
        let client = makeClient(
            route: route,
            ticket: try ticket(authToken: "ticket-secret", route: route),
            capture: capture,
            transport: QueuedCancellationProbeTransport()
        )

        _ = try? await client.sendRequest(
            try MobileCoreRPCClient.requestData(method: "mobile.host.status")
        )

        #expect(capture.request()?.authorizationMode == .stackBearer)
    }

    @Test func nonTailscaleTicketCannotAuthorizeAGenericHostRoute() async throws {
        let route = try CmxAttachRoute(
            id: "generic-websocket",
            kind: .websocket,
            endpoint: .url("wss://example.test/mobile")
        )
        let capture = TransportRequestCapture()
        let transport = QueuedCancellationProbeTransport()
        let client = makeClient(
            route: route,
            ticket: try ticket(authToken: "ticket-secret", route: route),
            capture: capture,
            transport: transport
        )

        do {
            _ = try await client.sendRequest(
                try MobileCoreRPCClient.requestData(method: "workspace.list")
            )
            Issue.record("Expected the generic route to fail closed")
        } catch MobileShellConnectionError.insecureManualRoute {
        } catch {
            Issue.record("Expected insecureManualRoute, got \(error)")
        }

        #expect(capture.request() == nil)
        #expect(try await transport.sentRequests().isEmpty)
    }

    /// The Mac only discloses its identity to a caller that proves ownership, and
    /// the iOS build-compatibility policy fails CLOSED on a missing instance tag.
    /// So the ticket must ride `mobile.host.status` even though status needs no
    /// auth — otherwise a correctly paired phone rejects its own Mac.
    @Test func hostStatusCarriesTheAttachTokenSoIdentityIsDisclosed() async throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let client = makeClient(
            route: route,
            ticket: try ticket(authToken: "ticket-secret", route: route),
            capture: TransportRequestCapture(),
            transport: transport
        )

        _ = try? await client.sendRequest(
            try MobileCoreRPCClient.requestData(method: "mobile.host.status")
        )

        let sent = try await transport.waitForSentRequestCount(1)
        #expect(sent.first?.attachToken == "ticket-secret")
        #expect(sent.first?.stackAccessToken == nil)
    }

    /// The blocker Codex round 2 found: `sendRequest` takes caller-built JSON, and
    /// an `auth` block already present was passed through whenever this layer added
    /// nothing of its own. An EXPIRED ticket on `mobile.host.status` is exactly that
    /// case (status needs no auth, so expiry does not throw), which would have put a
    /// caller-supplied Stack bearer on the plaintext transport that exists only
    /// because no account credential crosses it.
    @Test func callerSuppliedStackTokenIsStrippedOnAnAttachTicketConnection() async throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465)
        let transport = QueuedCancellationProbeTransport()
        let client = makeClient(
            route: route,
            ticket: try ticket(
                authToken: "ticket-secret",
                route: route,
                expiresAt: Date().addingTimeInterval(-600)
            ),
            capture: TransportRequestCapture(),
            transport: transport
        )

        let smuggled = try JSONSerialization.data(withJSONObject: [
            "id": "smuggled",
            "method": "mobile.host.status",
            "params": [:],
            "auth": ["stack_access_token": "SHOULD-NEVER-BE-SENT"],
        ])

        _ = try? await client.sendRequest(smuggled)

        let sent = try await transport.waitForSentRequestCount(1)
        #expect(sent.first?.stackAccessToken == nil)
        #expect(sent.first?.hasAuth == false)
    }
}
