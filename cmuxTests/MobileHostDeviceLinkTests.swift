import CMUXMobileCore
import CmuxIrohTransport
import DeviceLinkKit
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Guards the boundaries that make DeviceLink admission meaningful.
///
/// These are the properties that stop being obvious the moment someone adds a
/// verb to the wrong switch, which is exactly how a management interface leaks
/// onto the network.
@Suite("DeviceLink host boundaries", .serialized)
struct MobileHostDeviceLinkTests {
    // MARK: - authorization contexts

    @Test func testEnrollmentCandidateMayOnlyEnroll() async {
        let authorization = MobileHostConnectionAuthorizationContext
            .enrollmentCandidate(fingerprint: String(repeating: "a", count: 64))

        let enroll = await MobileHostService.connectionAuthorizationError(
            for: makeRequest(method: "mobile.pairing.device.enroll"),
            authorization: authorization
        )
        #expect(enroll == nil, "an enrolling device must be able to complete enrollment")

        for method in [
            "mobile.terminal.input",
            "mobile.workspace.list",
            "workspace.create",
            "mobile.terminal.create",
        ] {
            let result = await MobileHostService.connectionAuthorizationError(
                for: makeRequest(method: method),
                authorization: authorization
            )
            guard case .failure = result else {
                Issue.record("unenrolled device was allowed to call \(method)")
                continue
            }
        }
    }

    @Test func testPairedDeviceMayWorkAndRetryItsOwnEnrollment() async {
        let authorization = MobileHostConnectionAuthorizationContext
            .pairedDevice(fingerprint: String(repeating: "b", count: 64), label: "iPhone 16")

        let input = await MobileHostService.connectionAuthorizationError(
            for: makeRequest(method: "mobile.terminal.input"),
            authorization: authorization
        )
        #expect(input == nil, "a paired device must be able to drive its Mac")

        let enroll = await MobileHostService.connectionAuthorizationError(
            for: makeRequest(method: "mobile.pairing.device.enroll"),
            authorization: authorization
        )
        #expect(
            enroll == nil,
            "a paired device may retry enrollment after a lost response; TLS fixes the request to its own key"
        )
    }

    @MainActor
    @Test func testSelfRevokeDerivesFingerprintFromAuthenticatedContext() async {
        let recorder = SelfRevokeRecorder()
        let connectionID = UUID()
        let authenticatedFingerprint = String(repeating: "d", count: 64)

        let result = await MobileHostService.deviceLinkSelfRevocationResult(
            authorization: .pairedDevice(
                fingerprint: authenticatedFingerprint,
                label: "Tim's iPhone"
            ),
            connectionID: connectionID,
            revoke: { fingerprint, connectionID in
                recorder.record(fingerprint: fingerprint, connectionID: connectionID)
                return true
            }
        )

        guard case let .ok(payload as [String: Any]) = result else {
            Issue.record("paired DeviceLink caller should be able to revoke itself")
            return
        }
        #expect(payload["revoked"] as? Bool == true)
        #expect(recorder.fingerprint == authenticatedFingerprint)
        #expect(recorder.connectionID == connectionID)
    }

    @MainActor
    @Test func selfRevokeRejectsEnrollmentCandidate() async {
        let recorder = SelfRevokeRecorder()
        let result = await MobileHostService.deviceLinkSelfRevocationResult(
            authorization: .enrollmentCandidate(fingerprint: String(repeating: "e", count: 64)),
            connectionID: UUID(),
            revoke: { fingerprint, connectionID in
                recorder.record(fingerprint: fingerprint, connectionID: connectionID)
                return true
            }
        )

        guard case let .failure(error) = result else {
            Issue.record("an enrollment candidate must not revoke any DeviceLink pairing")
            return
        }
        #expect(error.code == "unauthorized")
        #expect(recorder.fingerprint == nil)
    }

    @Test func testSuccessfulSelfRevokeFlushesResponseThenClosesLiveConnection() async throws {
        let requestPayload = try JSONSerialization.data(withJSONObject: [
            "id": "remove-1",
            "method": "mobile.pairing.device.revoke_self",
            "params": [:],
        ])
        let transport = SelfRevokeResponseTransport(
            firstFrame: try MobileSyncFrameCodec.encodeFrame(requestPayload)
        )
        let closeRecorder = SelfRevokeConnectionCloseRecorder()
        let connectionID = UUID()
        let connection = MobileHostConnection(
            id: connectionID,
            transport: transport,
            authorizeRequest: { _ in nil },
            onAuthorizedRequest: { _ in },
            handleRequest: { request in
                #expect(request.method == "mobile.pairing.device.revoke_self")
                return .ok(["revoked": true])
            },
            onClose: { id in await closeRecorder.record(id) }
        )

        let run = Task { await connection.run() }
        let sent = await transport.waitForSentFrame()
        _ = await run.value

        var buffer = sent
        let responses = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        let response = try #require(responses.first)
        let json = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        #expect(json["id"] as? String == "remove-1")
        #expect(await transport.closeCount == 1)
        #expect(await closeRecorder.ids == [connectionID])
    }

    @Test func irohAdmissionCannotReachDeviceLinkEnrollment() async throws {
        let result = await MobileHostService.deviceLinkEnrollmentResult(
            for: makeRequest(method: "mobile.pairing.device.enroll", params: ["ticket": "whatever"]),
            authorization: try irohAdmissionContext()
        )
        guard case let .failure(error) = result else {
            Issue.record("enrollment must require a DeviceLink connection")
            return
        }
        #expect(error.code == "unauthorized")
    }

    @Test func testEnrollmentRequiresATicket() async {
        let result = await MobileHostService.deviceLinkEnrollmentResult(
            for: makeRequest(method: "mobile.pairing.device.enroll"),
            authorization: .enrollmentCandidate(fingerprint: String(repeating: "c", count: 64))
        )
        guard case let .failure(error) = result else {
            Issue.record("enrollment without a ticket must fail")
            return
        }
        #expect(error.code == "invalid_request")
    }

    // MARK: - dispatch boundaries

    /// Device management must not be reachable from the network at all.
    ///
    /// A paired phone that could enumerate and revoke its siblings would turn
    /// one compromised device into control over every device — the property
    /// per-device revocation exists to prevent.
    @MainActor
    @Test func testDeviceManagementVerbsAreNotOnTheNetworkDispatch() async {
        for verb in ["mobile.pairing.device.list", "mobile.pairing.device.revoke"] {
            let result = await TerminalController.shared.mobileHostHandleRPC(
                makeRequest(method: verb)
            )
            guard case let .failure(error) = result else {
                Issue.record("\(verb) must stay on the local control socket")
                continue
            }
            #expect(error.code == "method_not_found")
        }
    }

    @Test func testEnrollmentVerbIsRecognizedExactly() {
        #expect(MobileHostService.isDeviceLinkEnrollmentMethod("mobile.pairing.device.enroll"))
        #expect(!MobileHostService.isDeviceLinkEnrollmentMethod("mobile.pairing.device.list"))
        #expect(!MobileHostService.isDeviceLinkEnrollmentMethod("mobile.terminal.input"))
        #expect(!MobileHostService.isDeviceLinkEnrollmentMethod(""))
    }

    @Test func testEnrollmentResponseCarriesMacIdentityWithoutSecondCandidateRPC() throws {
        let fingerprint = try #require(DeviceFingerprint(hex: String(repeating: "f", count: 64)))
        let now = Date()
        let device = AuthorizedDevice(
            fingerprint: fingerprint,
            label: "Test iPhone",
            createdAt: now,
            lastSeenAt: now
        )
        let response = MobileHostService.deviceLinkEnrollmentResponse(
            device: device,
            wasAlreadyEnrolled: false
        )

        #expect(response["mac_device_id"] as? String == MobileHostIdentity.deviceID())
        #expect(response["mac_instance_tag"] as? String == MobileHostIdentity.instanceTag())
        #expect(response["mac_display_name"] as? String == MobileHostIdentity.instanceDisplayName())
        #expect(response["device_label"] as? String == "Test iPhone")
        #expect(response["fingerprint"] as? String == fingerprint.hex)
    }

    // MARK: - helpers

    private func makeRequest(
        method: String,
        params: [String: Any] = [:]
    ) -> MobileHostRPCRequest {
        MobileHostRPCRequest(id: "1", method: method, params: params, auth: nil)
    }

    private func irohAdmissionContext() throws -> MobileHostConnectionAuthorizationContext {
        let endpointID = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        return .irohAdmission(CmxIrohAdmittedPeer(peer: CmxIrohGrantPeer(
            bindingID: "123e4567-e89b-42d3-a456-426614174001",
            deviceID: "123e4567-e89b-42d3-a456-426614174002",
            tag: "ios-test",
            platform: .ios,
            endpointID: endpointID,
            identityGeneration: 1
        )))
    }

    @MainActor
    private final class SelfRevokeRecorder {
        private(set) var fingerprint: String?
        private(set) var connectionID: UUID?

        func record(fingerprint: String, connectionID: UUID) {
            self.fingerprint = fingerprint
            self.connectionID = connectionID
        }
    }
}

private actor SelfRevokeResponseTransport: CmxByteTransport {
    private var firstFrame: Data?
    private var receiveWaiter: CheckedContinuation<Data?, Never>?
    private var sentFrames: [Data] = []
    private var sentWaiters: [CheckedContinuation<Data, Never>] = []
    private var isClosed = false
    private(set) var closeCount = 0

    init(firstFrame: Data) {
        self.firstFrame = firstFrame
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if let firstFrame {
            self.firstFrame = nil
            return firstFrame
        }
        if isClosed {
            return nil
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                receiveWaiter = continuation
            }
        } onCancel: {
            Task { await self.finishReceive() }
        }
    }

    func send(_ data: Data) async throws {
        sentFrames.append(data)
        let waiters = sentWaiters
        sentWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: data) }
    }

    func close() async {
        closeCount += 1
        isClosed = true
        finishReceive()
    }

    func waitForSentFrame() async -> Data {
        if let sent = sentFrames.first { return sent }
        return await withCheckedContinuation { sentWaiters.append($0) }
    }

    private func finishReceive() {
        receiveWaiter?.resume(returning: nil)
        receiveWaiter = nil
    }
}

private actor SelfRevokeConnectionCloseRecorder {
    private(set) var ids: [UUID] = []

    func record(_ id: UUID) {
        ids.append(id)
    }
}
