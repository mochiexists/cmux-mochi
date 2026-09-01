import CMUXMobileCore
import CmuxMobileTransport
import Foundation
import Network
import Testing
@testable import CmuxHive

@Suite("Hive mobile runtime")
struct HiveMobileRuntimeTests {
    @Test("resolves TLS from the immutable peer device and instance target")
    func resolvesExactPeerCredential() throws {
        let recorder = TLSRequestRecorder()
        let runtime = HiveMobileRuntime.network { request in
            recorder.record(request)
            return NWProtocolTLS.Options()
        }
        let route = try CmxAttachRoute(
            id: "lan",
            kind: .localNetwork,
            endpoint: .hostPort(host: "192.168.1.25", port: 3939)
        )
        let request = CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: "mac-a",
            expectedPeerInstanceTag: "nightly",
            authorizationMode: .transportAdmission
        )

        _ = try runtime.transportFactory.makeTransport(for: request)

        #expect(recorder.lastRequest?.expectedPeerDeviceID == "mac-a")
        #expect(recorder.lastRequest?.expectedPeerInstanceTag == "nightly")
    }
}

private final class TLSRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: CmxByteTransportRequest?

    var lastRequest: CmxByteTransportRequest? {
        lock.withLock { storedRequest }
    }

    func record(_ request: CmxByteTransportRequest) {
        lock.withLock { storedRequest = request }
    }
}
