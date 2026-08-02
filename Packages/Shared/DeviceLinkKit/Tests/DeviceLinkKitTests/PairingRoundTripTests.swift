import Foundation
import Testing

@testable import DeviceLinkKit

/// The join between the two halves of pairing: what a Mac encodes into a QR is
/// exactly what a phone can act on.
///
/// These halves live in different apps and are easy to drift apart, so the
/// contract is asserted here rather than discovered on a phone.
@Suite("Pairing round trip")
struct PairingRoundTripTests {
    @Test("a Mac's generated code carries everything the phone needs to pair")
    func generatedCodeIsActionable() async throws {
        // Mac side: a real identity and a real enrollment ticket.
        let macIdentity = try DeviceIdentityMaterial.generate(commonName: "cmux-mac")
        let coordinator = DeviceLinkCoordinator(store: EphemeralStore())
        let ticket = try await coordinator.issueEnrollmentTicket()

        let payload = PairingPayload(
            scheme: "cmux-ios",
            routes: ["100.64.1.2:41234"],
            macFingerprint: macIdentity.fingerprint,
            enrollmentTicket: ticket.secret,
            macLabel: "Tim's M5"
        )
        let url = try #require(PairingPayloadCoder.encode(payload))

        // Phone side: decode and use it.
        let decoded = try PairingPayloadCoder.decode(url)
        #expect(decoded.macFingerprint == macIdentity.fingerprint)
        #expect(decoded.enrollmentTicket == ticket.secret)
        #expect(decoded.routes == ["100.64.1.2:41234"])

        // The pin the phone stores must match the key the Mac will present.
        let presented = try #require(
            DeviceFingerprint(derEncodedCertificate: macIdentity.derEncodedCertificate)
        )
        #expect(presented == decoded.macFingerprint)

        // And the ticket must actually enroll the phone's own key.
        let phoneIdentity = try DeviceIdentityMaterial.generate(commonName: "cmux-iphone")
        let outcome = try await coordinator.redeem(
            ticketSecret: decoded.enrollmentTicket,
            fingerprint: phoneIdentity.fingerprint,
            rawLabel: "iPhone 16"
        )
        #expect(outcome.wasAlreadyEnrolled == false)
        #expect(await coordinator.isAuthorized(phoneIdentity.fingerprint))
    }

    @Test("a code from one Mac cannot enroll against a different Mac")
    func ticketsDoNotCrossMacs() async throws {
        let first = DeviceLinkCoordinator(store: EphemeralStore())
        let second = DeviceLinkCoordinator(store: EphemeralStore())
        let ticket = try await first.issueEnrollmentTicket()
        let phone = try DeviceIdentityMaterial.generate()

        await #expect(throws: EnrollmentError.ticketUnusable) {
            _ = try await second.redeem(
                ticketSecret: ticket.secret,
                fingerprint: phone.fingerprint,
                rawLabel: "wandering iPhone"
            )
        }
    }

    @Test("a Mac that regenerates its identity is a different pairing")
    func newMacIdentityIsANewPairing() throws {
        // Reinstalling cmux mints a new key. The phone's stored pin then no
        // longer matches, which is correct: the old key can no longer be
        // proven, so the pairing genuinely is gone rather than silently
        // transferring to whatever now answers on that address.
        let original = try DeviceIdentityMaterial.generate(commonName: "cmux-mac")
        let replacement = try DeviceIdentityMaterial.generate(commonName: "cmux-mac")
        #expect(original.fingerprint != replacement.fingerprint)
    }
}

/// Store that keeps the table only in memory, for tests that do not care about
/// persistence.
private actor EphemeralStore: AuthorizedDeviceStoring {
    private var data: Data?
    func load() async throws -> Data? { data }
    func save(_ newValue: Data) async throws { data = newValue }
}
