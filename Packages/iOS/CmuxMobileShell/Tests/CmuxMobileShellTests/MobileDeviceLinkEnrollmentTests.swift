import DeviceLinkKit
import Foundation
import Testing

@testable import CmuxMobileShell

@Suite("DeviceLink enrollment")
struct MobileDeviceLinkEnrollmentTests {
    private func fingerprint(_ seed: UInt8 = 0xAB) -> DeviceFingerprint {
        DeviceFingerprint(hex: String(repeating: String(format: "%02x", seed), count: 32))!
    }

    @Test("a pairing is keyed by the Mac's public key, not a device name")
    func pairingIDDerivesFromFingerprint() {
        let first = MobileDeviceLinkEnroller.pairingID(for: fingerprint(0x01))
        let second = MobileDeviceLinkEnroller.pairingID(for: fingerprint(0x02))
        #expect(first != second)
        #expect(first.contains(fingerprint(0x01).hex))
        // Stable across calls: the same Mac must resolve to the same pairing.
        #expect(first == MobileDeviceLinkEnroller.pairingID(for: fingerprint(0x01)))
    }

    @Test("host:port routes parse, including IPv6 literals")
    func routeParsing() {
        let tailnet = MobileDeviceLinkEnroller.splitHostPort("100.64.1.2:41234")
        #expect(tailnet?.host == "100.64.1.2")
        #expect(tailnet?.port == 41234)

        let ipv6 = MobileDeviceLinkEnroller.splitHostPort("[fd7a:115c:a1e0::1]:9000")
        #expect(ipv6?.host == "fd7a:115c:a1e0::1")
        #expect(ipv6?.port == 9000)

        #expect(MobileDeviceLinkEnroller.splitHostPort("no-port") == nil)
        #expect(MobileDeviceLinkEnroller.splitHostPort(":41234") == nil)
        #expect(MobileDeviceLinkEnroller.splitHostPort("host:0") == nil)
        #expect(MobileDeviceLinkEnroller.splitHostPort("host:70000") == nil)
    }

    @Test("frames carry a big-endian length prefix")
    func framing() {
        let framed = MobileDeviceLinkEnroller.frame(Data("hi".utf8))
        #expect(framed.count == 6)
        #expect(Array(framed.prefix(4)) == [0x00, 0x00, 0x00, 0x02])
        #expect(framed.suffix(2) == Data("hi".utf8))
    }

    @Test("a payload with no routes fails before any key work happens")
    func emptyRoutesRejected() async {
        let enroller = MobileDeviceLinkEnroller(deviceLabel: "test iPhone")
        let payload = PairingPayload(
            scheme: "cmux-ios",
            routes: [],
            macFingerprint: fingerprint(),
            enrollmentTicket: "ticket"
        )
        await #expect(throws: MobileDeviceLinkEnrollmentError.noRoutes) {
            _ = try await enroller.enroll(payload: payload)
        }
    }
}
