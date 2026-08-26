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
@Suite("DeviceLink host boundaries")
struct MobileHostDeviceLinkTests {
    // MARK: - authorization contexts

    @Test func testEnrollmentCandidateMayOnlyEnroll() async {
        let authorization = MobileHostConnectionAuthorizationContext
            .enrollmentCandidate(fingerprint: String(repeating: "a", count: 64))

        let enroll = await MobileHostService.connectionAuthorizationError(
            for: makeRequest(method: "mobile.pairing.device.enroll"),
            authorization: authorization,
            stackAuthorization: { _ in nil }
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
                authorization: authorization,
                stackAuthorization: { _ in nil }
            )
            guard case .failure = result else {
                Issue.record("unenrolled device was allowed to call \(method)")
                continue
            }
        }
    }

    @Test func testPairedDeviceMayWorkButNotEnroll() async {
        let authorization = MobileHostConnectionAuthorizationContext
            .pairedDevice(fingerprint: String(repeating: "b", count: 64), label: "iPhone 16")

        let input = await MobileHostService.connectionAuthorizationError(
            for: makeRequest(method: "mobile.terminal.input"),
            authorization: authorization,
            stackAuthorization: { _ in nil }
        )
        #expect(input == nil, "a paired device must be able to drive its Mac")

        let enroll = await MobileHostService.connectionAuthorizationError(
            for: makeRequest(method: "mobile.pairing.device.enroll"),
            authorization: authorization,
            stackAuthorization: { _ in nil }
        )
        guard case .failure = enroll else {
            Issue.record("a paired device must not be able to mint further pairings")
            return
        }
    }

    @Test func testStackBearerCannotReachEnrollment() async {
        let result = await MobileHostService.deviceLinkEnrollmentResult(
            for: makeRequest(method: "mobile.pairing.device.enroll", params: ["ticket": "whatever"]),
            authorization: .stackBearer
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
    @Test func testDeviceManagementVerbsAreNotOnTheNetworkDispatch() throws {
        let source = try networkDispatchSource()
        for verb in ["mobile.pairing.device.list", "mobile.pairing.device.revoke"] {
            #expect(
                !source.contains("case \"\(verb)\""),
                "\(verb) must stay on the local control socket, never mobileHostHandleRPC"
            )
        }
    }

    @Test func testEnrollmentVerbIsRecognizedExactly() {
        #expect(MobileHostService.isDeviceLinkEnrollmentMethod("mobile.pairing.device.enroll"))
        #expect(!MobileHostService.isDeviceLinkEnrollmentMethod("mobile.pairing.device.list"))
        #expect(!MobileHostService.isDeviceLinkEnrollmentMethod("mobile.terminal.input"))
        #expect(!MobileHostService.isDeviceLinkEnrollmentMethod(""))
    }

    @Test func testEnrollmentResponseCarriesMacIdentityWithoutSecondCandidateRPC() throws {
        let source = try deviceLinkHostSource()
        guard let methodStart = source.range(of: "deviceLinkEnrollmentResult("),
              let nextExtension = source.range(
                  of: "extension MobileHostService {",
                  range: methodStart.upperBound ..< source.endIndex
              )
        else {
            throw DispatchGuardError.enrollmentHandlerNotFound
        }
        let handler = source[methodStart.lowerBound ..< nextExtension.lowerBound]

        for key in ["mac_device_id", "mac_instance_tag", "mac_display_name"] {
            #expect(
                handler.contains("\"\(key)\""),
                "enrollment must return \(key); the candidate connection cannot make a second status RPC"
            )
        }
    }

    // MARK: - helpers

    private func makeRequest(
        method: String,
        params: [String: Any] = [:]
    ) -> MobileHostRPCRequest {
        MobileHostRPCRequest(id: "1", method: method, params: params, auth: nil)
    }

    /// Reads the network RPC dispatch so the assertion is about the shipping
    /// switch rather than a copy of it that could drift.
    private func networkDispatchSource() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let controller = repositoryRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("TerminalController.swift")
        let source = try String(contentsOf: controller, encoding: .utf8)
        guard let range = source.range(of: "func mobileHostHandleRPC") else {
            throw DispatchGuardError.dispatchNotFound
        }
        return String(source[range.lowerBound...])
    }

    private func deviceLinkHostSource() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources")
                .appendingPathComponent("Mobile")
                .appendingPathComponent("MobileHostService+DeviceLink.swift"),
            encoding: .utf8
        )
    }

    /// Raised when the dispatch this guard inspects has been renamed. Failing
    /// loudly beats a guard that silently stops guarding.
    private enum DispatchGuardError: Error {
        case dispatchNotFound
        case enrollmentHandlerNotFound
    }
}
