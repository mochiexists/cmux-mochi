import DeviceLinkKit
import Foundation
import Testing
@testable import CmuxHive

@Suite("Hive pairing link decoder")
struct HivePairingLinkDecoderTests {
    @Test("accepts the DeviceLink v3 link and preserves LAN-first routes")
    func decodesDeviceLinkPayload() throws {
        let fingerprint = try #require(
            DeviceFingerprint(
                hex: String(repeating: "ab", count: 32)
            )
        )
        let payload = PairingPayload(
            scheme: "cmux-ios-dev",
            routes: ["192.168.1.25:3939", "100.64.0.8:3939"],
            macFingerprint: fingerprint,
            enrollmentTicket: "single-use-ticket",
            macLabel: "Studio"
        )
        let url = try #require(PairingPayloadCoder.encode(payload))

        let decoded = try HivePairingLinkDecoder().decode(url.absoluteString)

        #expect(decoded == payload)
    }

    @Test("rejects legacy attach links instead of reviving bearer auth")
    func rejectsLegacyAttachLink() {
        #expect(throws: HivePairingLinkError.invalidLink) {
            _ = try HivePairingLinkDecoder().decode(
                "cmux-ios://attach?v=2&r=100.64.0.8:3939&token=legacy"
            )
        }
    }
}
