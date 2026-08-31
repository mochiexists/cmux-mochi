import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

/// Fork invariant: application requests carry no Stack or attach credential.
/// The immutable transport request is the complete peer-authorization boundary.
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
        MobileCoreRPCClient(
            runtime: TestMobileSyncRuntime(
                transportFactory: IntentRecordingTransportFactory(
                    transport: transport,
                    capture: capture
                ),
                rpcRequestTimeoutNanoseconds: 200_000_000
            ),
            route: route,
            ticket: ticket,
            expectedPeerInstanceTag: "nightly"
        )
    }

    @Test(arguments: [
        CmxAttachTransportKind.tailscale,
        CmxAttachTransportKind.debugLoopback,
    ])
    func networkRoutesDeclareTransportAdmission(
        kind: CmxAttachTransportKind
    ) async throws {
        let host = kind == .tailscale ? "100.64.0.5" : "127.0.0.1"
        let route = try hostPortRoute(kind: kind, host: host, port: 58_465)
        let capture = TransportRequestCapture()
        let client = makeClient(
            route: route,
            ticket: try ticket(authToken: "obsolete-ticket", route: route),
            capture: capture,
            transport: QueuedCancellationProbeTransport()
        )

        _ = try? await client.sendRequest(
            try MobileCoreRPCClient.requestData(method: "mobile.host.status")
        )

        let request = try #require(capture.request())
        #expect(request.authorizationMode == .transportAdmission)
        #expect(request.expectedPeerDeviceID == "mac-1")
        #expect(request.expectedPeerInstanceTag == "nightly")
    }

    @Test func ticketAndCallerCredentialsNeverCrossTransport() async throws {
        let route = try hostPortRoute(
            kind: .tailscale,
            host: "100.64.0.5",
            port: 58_465
        )
        let transport = QueuedCancellationProbeTransport()
        let client = makeClient(
            route: route,
            ticket: try ticket(
                authToken: "obsolete-ticket",
                route: route,
                expiresAt: Date().addingTimeInterval(-600)
            ),
            capture: TransportRequestCapture(),
            transport: transport
        )
        let request = try JSONSerialization.data(withJSONObject: [
            "id": "smuggled",
            "method": "workspace.list",
            "params": [:],
            "auth": [
                "stack_access_token": "SHOULD-NEVER-BE-SENT",
                "attach_token": "ALSO-NEVER-SENT",
            ],
        ])

        _ = try? await client.sendRequest(request)

        let sent = try await transport.waitForSentRequestCount(1)
        let frame = try #require(sent.first)
        #expect(frame.hasAuth == false)
        #expect(frame.stackAccessToken == nil)
        #expect(frame.attachToken == nil)
    }
}
