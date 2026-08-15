import Foundation
import Testing

@testable import DeviceLinkKit

private func fingerprint(_ seed: UInt8 = 0xAB) -> DeviceFingerprint {
    DeviceFingerprint(hex: String(repeating: String(format: "%02x", seed), count: 32))!
}

@Suite("Pairing payload")
struct PairingPayloadTests {
    @Test("a payload round-trips through its URL form")
    func roundTrip() throws {
        let payload = PairingPayload(
            scheme: "cmux-ios",
            routes: ["100.64.1.2:41234", "100.64.1.2:9999"],
            macFingerprint: fingerprint(),
            enrollmentTicket: "ticket-abc",
            macLabel: "Tim's M5"
        )
        let url = try #require(PairingPayloadCoder.encode(payload))
        let decoded = try PairingPayloadCoder.decode(url)
        #expect(decoded == payload)
    }

    @Test("the encoded payload carries no bearer beyond the enrollment ticket")
    func carriesNoDurableCredential() throws {
        let payload = PairingPayload(
            scheme: "cmux-ios",
            routes: ["100.64.1.2:41234"],
            macFingerprint: fingerprint(),
            enrollmentTicket: "ticket-abc"
        )
        let url = try #require(PairingPayloadCoder.encode(payload))
        let query = url.query ?? ""
        // The legacy grammars carried `k=` (auth token) and `x=` (its expiry).
        // Their absence is the point of this design; assert it structurally.
        #expect(!query.contains("k="))
        #expect(!query.contains("x="))
        #expect(query.contains("f=\(payload.macFingerprint.hex)"))
    }

    @Test("an older grammar version is rejected distinctly")
    func rejectsOldVersions() throws {
        let url = try #require(URL(string: "cmux-ios://pair?v=2&r=host:1&f=\(fingerprint().hex)&t=abc"))
        #expect(throws: PairingPayloadCoder.DecodingError.unsupportedVersion(2)) {
            _ = try PairingPayloadCoder.decode(url)
        }
    }

    @Test("a malformed fingerprint is refused")
    func rejectsBadFingerprint() throws {
        let url = try #require(URL(string: "cmux-ios://pair?v=3&r=host:1&f=nothex&t=abc"))
        #expect(throws: PairingPayloadCoder.DecodingError.missingFingerprint) {
            _ = try PairingPayloadCoder.decode(url)
        }
    }

    @Test("a payload without routes or ticket is refused")
    func rejectsIncompletePayloads() throws {
        let noTicket = try #require(URL(string: "cmux-ios://pair?v=3&r=host:1&f=\(fingerprint().hex)"))
        #expect(throws: PairingPayloadCoder.DecodingError.missingTicket) {
            _ = try PairingPayloadCoder.decode(noTicket)
        }
        let noRoutes = try #require(URL(string: "cmux-ios://pair?v=3&f=\(fingerprint().hex)&t=abc"))
        #expect(throws: PairingPayloadCoder.DecodingError.missingRoutes) {
            _ = try PairingPayloadCoder.decode(noRoutes)
        }
    }

    @Test("a legacy attach payload is refused by version, not by host")
    func rejectsLegacyPayloads() throws {
        // DeviceLink shares the `attach` host because that is the deep link iOS
        // already routes to the app, so the version is what separates the
        // grammars. A legacy code must fail as "wrong version" - which the UI
        // can explain - rather than "not a pairing link".
        let legacy = try #require(URL(string: "cmux-ios://attach?payload=whatever"))
        #expect(PairingPayloadCoder.isPairingURL(legacy))
        #expect(throws: PairingPayloadCoder.DecodingError.unsupportedVersion(nil)) {
            _ = try PairingPayloadCoder.decode(legacy)
        }
    }

    @Test("URLs for other hosts are not pairing links")
    func rejectsUnrelatedHosts() throws {
        let unrelated = try #require(URL(string: "cmux-ios://settings?tab=general"))
        #expect(PairingPayloadCoder.isPairingURL(unrelated) == false)
        #expect(throws: PairingPayloadCoder.DecodingError.notAPairingURL) {
            _ = try PairingPayloadCoder.decode(unrelated)
        }
    }
}

@Suite("Reconnect policy")
struct ReconnectPolicyTests {
    @Test("a pin mismatch stops immediately instead of retrying an impostor")
    func pinMismatchIsTerminal() {
        let policy = ReconnectPolicy.default
        #expect(policy.decision(after: .serverPinMismatch, attempt: 1, randomFraction: 0) == .stopAndRequirePairing)
        #expect(policy.decision(after: .rejectedByPeer, attempt: 1, randomFraction: 0) == .stopAndRequirePairing)
    }

    @Test("unreachable endpoints back off exponentially up to the cap")
    func backoffLadder() {
        let policy = ReconnectPolicy(baseDelay: 1, maximumDelay: 16, jitterFraction: 0, healthyResetInterval: 30)
        #expect(policy.delay(forAttempt: 1, randomFraction: 0) == 1)
        #expect(policy.delay(forAttempt: 2, randomFraction: 0) == 2)
        #expect(policy.delay(forAttempt: 3, randomFraction: 0) == 4)
        #expect(policy.delay(forAttempt: 4, randomFraction: 0) == 8)
        #expect(policy.delay(forAttempt: 5, randomFraction: 0) == 16)
        #expect(policy.delay(forAttempt: 99, randomFraction: 0) == 16)
    }

    @Test("jitter spreads a waking fleet instead of synchronizing it")
    func jitterApplies() {
        let policy = ReconnectPolicy(baseDelay: 4, maximumDelay: 16, jitterFraction: 0.5, healthyResetInterval: 30)
        let low = policy.delay(forAttempt: 1, randomFraction: 0)
        let high = policy.delay(forAttempt: 1, randomFraction: 1)
        #expect(low == 4)
        #expect(high == 6)
        #expect(policy.delay(forAttempt: 1, randomFraction: 0.5) == 5)
    }

    @Test("foreground resume always bypasses backoff")
    func foregroundBypass() {
        #expect(ReconnectPolicy.default.shouldBypassBackoffOnForeground())
    }
}

@Suite("Endpoint resolution")
struct EndpointResolutionTests {
    @Test("stored routes are dialed before directory advertisements")
    func storedRoutesWinOrdering() {
        let order = EndpointResolution.dialOrder(
            stored: ["100.64.1.2:41234"],
            advertised: ["100.64.1.2:50000", "100.64.1.2:41234"]
        )
        #expect(order == ["100.64.1.2:41234", "100.64.1.2:50000"])
    }

    @Test("empty and duplicate routes are dropped")
    func deduplicates() {
        let order = EndpointResolution.dialOrder(
            stored: ["a:1", "", "a:1"],
            advertised: ["b:2", "b:2"]
        )
        #expect(order == ["a:1", "b:2"])
    }

    @Test("no directory means the stored routes are the whole plan")
    func worksWithoutDirectory() {
        #expect(EndpointResolution.dialOrder(stored: ["a:1"], advertised: []) == ["a:1"])
    }
}
