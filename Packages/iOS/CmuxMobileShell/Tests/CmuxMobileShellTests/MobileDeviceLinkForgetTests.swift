import DeviceLinkKit
import Foundation
import Testing

@testable import CmuxMobileShell

/// Deleting a computer must destroy the credential, not just the row.
///
/// The unpair path used to remove the `paired_macs` row and leave the keychain
/// identity, the pin, and the Mac -> pairing mapping behind. The phone then
/// still reported itself paired with nothing listed, and re-scanning the same
/// Mac's QR code reused the old identity, so the Mac answered "already
/// enrolled" — a delete that deleted nothing and a re-pair that never happened.
@Suite("DeviceLink forget and re-pair")
struct MobileDeviceLinkForgetTests {
    private func fingerprint(_ seed: UInt8) -> DeviceFingerprint {
        DeviceFingerprint(hex: String(repeating: String(format: "%02x", seed), count: 32))!
    }

    /// A client scoped to this test, so it cannot see or disturb real pairings.
    private func makeClient(_ label: String) -> MobileDeviceLinkClient {
        MobileDeviceLinkClient(
            scope: KeychainScope(bundleIdentifier: "com.cmux-mochi.tests.\(label)")
        )
    }

    private func cleanUp(_ client: MobileDeviceLinkClient, macs: [String]) {
        for mac in macs { client.forgetPairing(macDeviceID: mac) }
    }

    @Test("forgetting one Mac destroys its credential and leaves the other alone")
    func forgetOneMacOfTwo() throws {
        let client = makeClient("forget-one")
        let macA = "AAAA0000-0000-0000-0000-00000000000A"
        let macB = "BBBB0000-0000-0000-0000-00000000000B"
        defer { cleanUp(client, macs: [macA, macB]) }

        let pinA = fingerprint(0x11)
        let pinB = fingerprint(0x22)
        let pairingA = MobileDeviceLinkEnroller.pairingID(for: pinA)
        let pairingB = MobileDeviceLinkEnroller.pairingID(for: pinB)

        _ = try client.prepareIdentity(forPairingID: pairingA, macFingerprint: pinA)
        _ = try client.prepareIdentity(forPairingID: pairingB, macFingerprint: pinB)
        client.rememberPairing(macDeviceID: macA, pairingID: pairingA)
        client.rememberPairing(macDeviceID: macB, pairingID: pairingB)

        #expect(client.hasUsableCredential(forPairingID: pairingA))
        #expect(client.hasUsableCredential(forPairingID: pairingB))

        let forgotten = client.forgetPairing(macDeviceID: macA)

        #expect(forgotten == pairingA)
        // The deleted Mac keeps nothing that could be reused.
        #expect(!client.hasUsableCredential(forPairingID: pairingA))
        #expect(client.pin(forPairingID: pairingA) == nil)
        // The Mac that was NOT deleted is untouched — the key is per-Mac.
        #expect(client.hasUsableCredential(forPairingID: pairingB))
        #expect(client.pin(forPairingID: pairingB) == pinB)
        // Still paired overall, so the device stays authenticated.
        #expect(client.hasAnyPairedDevice())
    }

    @Test("forgetting the last Mac leaves the device genuinely unpaired")
    func forgetLastMac() throws {
        let client = makeClient("forget-last")
        let mac = "CCCC0000-0000-0000-0000-00000000000C"
        defer { cleanUp(client, macs: [mac]) }

        let pin = fingerprint(0x33)
        let pairing = MobileDeviceLinkEnroller.pairingID(for: pin)
        _ = try client.prepareIdentity(forPairingID: pairing, macFingerprint: pin)
        client.rememberPairing(macDeviceID: mac, pairingID: pairing)
        #expect(client.hasAnyPairedDevice())

        client.forgetPairing(macDeviceID: mac)

        // This is what the reconnect gate and the auth-sync guard both read.
        // While it stayed true, the shell reported a paired device with no Mac
        // to dial and no way for the user to get back to a pairing screen.
        #expect(!client.hasAnyPairedDevice())
        #expect(client.forgetPairing(macDeviceID: mac) == nil)
    }

    @Test("re-pairing after a delete issues a NEW device key")
    func rePairAfterDeleteIssuesFreshIdentity() throws {
        let client = makeClient("re-pair")
        let mac = "DDDD0000-0000-0000-0000-00000000000D"
        defer { cleanUp(client, macs: [mac]) }

        let pin = fingerprint(0x44)
        let pairing = MobileDeviceLinkEnroller.pairingID(for: pin)

        let first = try client.prepareIdentity(forPairingID: pairing, macFingerprint: pin)
        client.rememberPairing(macDeviceID: mac, pairingID: pairing)

        client.forgetPairing(macDeviceID: mac)
        #expect(!client.hasAnyPairedDevice())

        // Scanning the same Mac's QR code again, exactly as the user would.
        let second = try client.prepareIdentity(forPairingID: pairing, macFingerprint: pin)
        client.rememberPairing(macDeviceID: mac, pairingID: pairing)

        #expect(client.hasUsableCredential(forPairingID: pairing))
        #expect(client.pin(forPairingID: pairing) == pin)
        // A genuine re-pair, not a silent reuse: the Mac must see a fingerprint
        // it has not authorized, so it enrolls the phone rather than answering
        // "already enrolled" and admitting a key the user meant to revoke.
        #expect(first.fingerprint != second.fingerprint)
        #expect(first.derEncodedCertificate != second.derEncodedCertificate)
    }

    @Test("a forgotten Mac cannot pull another Mac's key through the dial index")
    func forgottenMacDoesNotResolveToAnotherMacsIdentity() throws {
        let client = makeClient("dial-index")
        let macA = "EEEE0000-0000-0000-0000-00000000000E"
        let macB = "FFFF0000-0000-0000-0000-00000000000F"
        defer { cleanUp(client, macs: [macA, macB]) }

        let pinA = fingerprint(0x55)
        let pinB = fingerprint(0x66)
        let pairingA = MobileDeviceLinkEnroller.pairingID(for: pinA)
        let pairingB = MobileDeviceLinkEnroller.pairingID(for: pinB)
        _ = try client.prepareIdentity(forPairingID: pairingA, macFingerprint: pinA)
        _ = try client.prepareIdentity(forPairingID: pairingB, macFingerprint: pinB)
        client.rememberPairing(macDeviceID: macA, pairingID: pairingA)
        client.rememberPairing(macDeviceID: macB, pairingID: pairingB)

        // Point the next dial at A, then delete A — the ordering that used to
        // leave a live dial target aimed at a destroyed identity.
        client.setActiveDialTarget(macDeviceID: macA)
        client.forgetPairing(macDeviceID: macA)

        // B is still dialable, and asking for A's pairing finds nothing.
        #expect(client.pin(forPairingID: pairingA) == nil)
        #expect(client.hasUsableCredential(forPairingID: pairingB))
    }
}
