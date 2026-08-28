import Foundation
import Testing

@testable import DeviceLinkKit

/// In-memory store with injectable failure, so persistence-ordering guarantees
/// can be tested without a keychain.
private actor MemoryStore: AuthorizedDeviceStoring {
    private var data: Data?
    private(set) var saveCount = 0
    var failNextSave = false

    init(seed: Data? = nil) { data = seed }

    func load() async throws -> Data? { data }

    func save(_ newValue: Data) async throws {
        if failNextSave {
            failNextSave = false
            throw NSError(domain: "test", code: 1)
        }
        data = newValue
        saveCount += 1
    }

    func setFailNextSave(_ value: Bool) { failNextSave = value }
    func snapshot() -> Data? { data }
}

private func makeFingerprint(_ seed: UInt8) -> DeviceFingerprint {
    let hex = String(repeating: String(format: "%02x", seed), count: 32)
    return DeviceFingerprint(hex: hex)!
}

@Suite("Enrollment")
struct EnrollmentTests {
    @Test("a valid ticket enrolls an unknown fingerprint exactly once")
    func enrollsUnknownDevice() async throws {
        let store = MemoryStore()
        let coordinator = DeviceLinkCoordinator(store: store)
        try await coordinator.load()
        let ticket = try await coordinator.issueEnrollmentTicket()
        let fingerprint = makeFingerprint(0xAB)

        let outcome = try await coordinator.redeem(
            ticketSecret: ticket.secret,
            fingerprint: fingerprint,
            rawLabel: "iPhone 16"
        )

        #expect(outcome.wasAlreadyEnrolled == false)
        #expect(outcome.device.label == "iPhone 16")
        #expect(await coordinator.isAuthorized(fingerprint))
        #expect(await coordinator.devices().count == 1)
    }

    @Test("a spent ticket cannot enroll a second device")
    func ticketIsSingleUse() async throws {
        let store = MemoryStore()
        let coordinator = DeviceLinkCoordinator(store: store)
        try await coordinator.load()
        let ticket = try await coordinator.issueEnrollmentTicket()
        _ = try await coordinator.redeem(
            ticketSecret: ticket.secret,
            fingerprint: makeFingerprint(0x01),
            rawLabel: "first"
        )

        await #expect(throws: EnrollmentError.ticketUnusable) {
            _ = try await coordinator.redeem(
                ticketSecret: ticket.secret,
                fingerprint: makeFingerprint(0x02),
                rawLabel: "second"
            )
        }
        #expect(await coordinator.isAuthorized(makeFingerprint(0x02)) == false)
    }

    @Test("an expired ticket is refused")
    func expiredTicketRefused() async throws {
        let store = MemoryStore()
        let coordinator = DeviceLinkCoordinator(store: store)
        try await coordinator.load()
        let start = Date()
        let ticket = try await coordinator.issueEnrollmentTicket(lifetime: 60, now: start)

        await #expect(throws: EnrollmentError.ticketUnusable) {
            _ = try await coordinator.redeem(
                ticketSecret: ticket.secret,
                fingerprint: makeFingerprint(0x03),
                rawLabel: "late",
                now: start.addingTimeInterval(61)
            )
        }
    }

    @Test("re-enrolling a known fingerprint is idempotent and spends no quota")
    func reEnrollmentIsIdempotent() async throws {
        let store = MemoryStore()
        let coordinator = DeviceLinkCoordinator(store: store)
        try await coordinator.load()
        let fingerprint = makeFingerprint(0x04)
        let first = try await coordinator.issueEnrollmentTicket()
        _ = try await coordinator.redeem(
            ticketSecret: first.secret,
            fingerprint: fingerprint,
            rawLabel: "iPhone 16"
        )

        // Simulates the lost-response retry: same device, fresh ticket.
        let second = try await coordinator.issueEnrollmentTicket()
        let outcome = try await coordinator.redeem(
            ticketSecret: second.secret,
            fingerprint: fingerprint,
            rawLabel: "iPhone 16 renamed"
        )

        #expect(outcome.wasAlreadyEnrolled)
        #expect(outcome.device.label == "iPhone 16 renamed")
        #expect(await coordinator.devices().count == 1)
    }

    @Test("a failed save leaves the ticket redeemable and the table unchanged")
    func persistenceFailureLeavesTicketUsable() async throws {
        let store = MemoryStore()
        let coordinator = DeviceLinkCoordinator(store: store)
        try await coordinator.load()
        let ticket = try await coordinator.issueEnrollmentTicket()
        let fingerprint = makeFingerprint(0x05)
        await store.setFailNextSave(true)

        await #expect(throws: EnrollmentError.persistenceFailed) {
            _ = try await coordinator.redeem(
                ticketSecret: ticket.secret,
                fingerprint: fingerprint,
                rawLabel: "flaky"
            )
        }
        #expect(await coordinator.isAuthorized(fingerprint) == false)

        // The ticket survived, so the retry succeeds.
        let retry = try await coordinator.redeem(
            ticketSecret: ticket.secret,
            fingerprint: fingerprint,
            rawLabel: "flaky"
        )
        #expect(retry.wasAlreadyEnrolled == false)
        #expect(await coordinator.isAuthorized(fingerprint))
    }

    @Test("concurrent redemptions of one ticket admit exactly one device")
    func concurrentRedemptionAdmitsOne() async throws {
        let store = MemoryStore()
        let coordinator = DeviceLinkCoordinator(store: store)
        try await coordinator.load()
        let ticket = try await coordinator.issueEnrollmentTicket()

        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for index in 0 ..< 8 {
                group.addTask {
                    let outcome = try? await coordinator.redeem(
                        ticketSecret: ticket.secret,
                        fingerprint: makeFingerprint(UInt8(0x10 + index)),
                        rawLabel: "racer \(index)"
                    )
                    return outcome != nil
                }
            }
            var collected: [Bool] = []
            for await value in group { collected.append(value) }
            return collected
        }

        #expect(results.filter { $0 }.count == 1)
        #expect(await coordinator.devices().count == 1)
    }

    @Test("device quota is enforced")
    func quotaEnforced() async throws {
        let store = MemoryStore()
        let coordinator = DeviceLinkCoordinator(
            store: store,
            policy: .init(maximumDevices: 2, minimumEnrollmentInterval: 0)
        )
        try await coordinator.load()
        for index in 0 ..< 2 {
            let ticket = try await coordinator.issueEnrollmentTicket()
            _ = try await coordinator.redeem(
                ticketSecret: ticket.secret,
                fingerprint: makeFingerprint(UInt8(0x20 + index)),
                rawLabel: "device \(index)"
            )
        }

        let overflow = try await coordinator.issueEnrollmentTicket()
        await #expect(throws: EnrollmentError.deviceQuotaExceeded) {
            _ = try await coordinator.redeem(
                ticketSecret: overflow.secret,
                fingerprint: makeFingerprint(0x2F),
                rawLabel: "one too many"
            )
        }
    }

    @Test("enrollment throttle rejects a rapid second device")
    func throttleEnforced() async throws {
        let store = MemoryStore()
        let coordinator = DeviceLinkCoordinator(
            store: store,
            policy: .init(maximumDevices: 16, minimumEnrollmentInterval: 60)
        )
        try await coordinator.load()
        let start = Date()
        let first = try await coordinator.issueEnrollmentTicket(now: start)
        _ = try await coordinator.redeem(
            ticketSecret: first.secret,
            fingerprint: makeFingerprint(0x30),
            rawLabel: "first",
            now: start
        )

        let second = try await coordinator.issueEnrollmentTicket(now: start)
        await #expect(throws: EnrollmentError.throttled) {
            _ = try await coordinator.redeem(
                ticketSecret: second.secret,
                fingerprint: makeFingerprint(0x31),
                rawLabel: "too soon",
                now: start.addingTimeInterval(5)
            )
        }
    }

    @Test("no enrollment window means no open tickets")
    func enrollmentWindowReflectsTickets() async throws {
        let store = MemoryStore()
        let coordinator = DeviceLinkCoordinator(store: store)
        try await coordinator.load()
        let start = Date()
        #expect(await coordinator.hasOpenEnrollmentWindow(now: start) == false)

        _ = try await coordinator.issueEnrollmentTicket(lifetime: 60, now: start)
        #expect(await coordinator.hasOpenEnrollmentWindow(now: start))
        #expect(await coordinator.hasOpenEnrollmentWindow(now: start.addingTimeInterval(61)) == false)
    }
}

@Suite("Revocation")
struct RevocationTests {
    @Test("revoking removes the row and closes its connections")
    func revokeClosesConnections() async throws {
        let store = MemoryStore()
        let coordinator = DeviceLinkCoordinator(store: store)
        try await coordinator.load()
        let ticket = try await coordinator.issueEnrollmentTicket()
        let fingerprint = makeFingerprint(0x40)
        _ = try await coordinator.redeem(
            ticketSecret: ticket.secret,
            fingerprint: fingerprint,
            rawLabel: "doomed"
        )

        let closed = Mutex<Set<UUID>>([])
        await coordinator.setConnectionCloser { ids in closed.withLock { $0.formUnion(ids) } }
        let connectionID = UUID()
        #expect(await coordinator.registerAdmission(fingerprint, connectionID: connectionID))

        #expect(try await coordinator.revoke(fingerprint))
        #expect(await coordinator.isAuthorized(fingerprint) == false)
        #expect(closed.withLock { $0 } == [connectionID])
    }

    @Test("self-revoke lets the response connection flush and closes its siblings")
    func selfRevokeExcludesCurrentConnection() async throws {
        let coordinator = DeviceLinkCoordinator(store: MemoryStore())
        try await coordinator.load()
        let ticket = try await coordinator.issueEnrollmentTicket()
        let fingerprint = makeFingerprint(0x42)
        _ = try await coordinator.redeem(
            ticketSecret: ticket.secret,
            fingerprint: fingerprint,
            rawLabel: "iPhone"
        )
        let currentConnectionID = UUID()
        let siblingConnectionID = UUID()
        #expect(await coordinator.registerAdmission(
            fingerprint,
            connectionID: currentConnectionID
        ))
        #expect(await coordinator.registerAdmission(
            fingerprint,
            connectionID: siblingConnectionID
        ))
        let closed = Mutex<Set<UUID>>([])
        await coordinator.setConnectionCloser { ids in
            closed.withLock { $0.formUnion(ids) }
        }

        #expect(try await coordinator.revoke(
            fingerprint,
            excludingConnectionID: currentConnectionID
        ))

        #expect(await coordinator.isAuthorized(fingerprint) == false)
        #expect(closed.withLock { $0 } == [siblingConnectionID])
    }

    @Test("admission after revocation is refused")
    func admissionAfterRevokeRefused() async throws {
        let store = MemoryStore()
        let coordinator = DeviceLinkCoordinator(store: store)
        try await coordinator.load()
        let ticket = try await coordinator.issueEnrollmentTicket()
        let fingerprint = makeFingerprint(0x41)
        _ = try await coordinator.redeem(
            ticketSecret: ticket.secret,
            fingerprint: fingerprint,
            rawLabel: "revoked"
        )
        _ = try await coordinator.revoke(fingerprint)

        // A handshake that verified just before the revoke must still fail to
        // register — this is the linearizability guarantee.
        #expect(await coordinator.registerAdmission(fingerprint, connectionID: UUID()) == false)
    }

    @Test("revoking one device leaves others untouched")
    func revokeIsolation() async throws {
        let store = MemoryStore()
        let coordinator = DeviceLinkCoordinator(
            store: store,
            policy: .init(maximumDevices: 16, minimumEnrollmentInterval: 0)
        )
        try await coordinator.load()
        let keep = makeFingerprint(0x50)
        let drop = makeFingerprint(0x51)
        for (fingerprint, label) in [(keep, "iPhone 17"), (drop, "iPhone 16")] {
            let ticket = try await coordinator.issueEnrollmentTicket()
            _ = try await coordinator.redeem(
                ticketSecret: ticket.secret,
                fingerprint: fingerprint,
                rawLabel: label
            )
        }

        _ = try await coordinator.revoke(drop)
        #expect(await coordinator.isAuthorized(keep))
        #expect(await coordinator.isAuthorized(drop) == false)
    }

    @Test("revoking an unknown fingerprint reports no change")
    func revokeUnknown() async throws {
        let coordinator = DeviceLinkCoordinator(store: MemoryStore())
        try await coordinator.load()
        #expect(try await coordinator.revoke(makeFingerprint(0x60)) == false)
    }
}

@Suite("Persistence")
struct PersistenceTests {
    @Test("the table round-trips across a restart")
    func roundTripsAcrossRestart() async throws {
        let store = MemoryStore()
        let fingerprint = makeFingerprint(0x70)
        do {
            let coordinator = DeviceLinkCoordinator(store: store)
            try await coordinator.load()
            let ticket = try await coordinator.issueEnrollmentTicket()
            _ = try await coordinator.redeem(
                ticketSecret: ticket.secret,
                fingerprint: fingerprint,
                rawLabel: "survivor"
            )
        }

        let reborn = DeviceLinkCoordinator(store: store)
        let wasRejected = try await reborn.load()
        #expect(wasRejected == false)
        #expect(await reborn.isAuthorized(fingerprint))
        // Tickets are in-memory only: a restart invalidates outstanding QRs.
        #expect(await reborn.hasOpenEnrollmentWindow() == false)
    }

    @Test("corrupt data yields an empty table and reports rejection")
    func corruptDataIsRejectedLoudly() async throws {
        let store = MemoryStore(seed: Data("not json".utf8))
        let coordinator = DeviceLinkCoordinator(store: store)
        let wasRejected = try await coordinator.load()
        #expect(wasRejected)
        #expect(await coordinator.devices().isEmpty)
    }

    @Test("an unknown schema version is rejected rather than guessed at")
    func futureVersionRejected() async throws {
        let future = """
        {"version":999,"devices":[]}
        """
        let coordinator = DeviceLinkCoordinator(store: MemoryStore(seed: Data(future.utf8)))
        #expect(try await coordinator.load())
    }
}

@Suite("Labels and fingerprints")
struct LabelAndFingerprintTests {
    @Test("labels are stripped of control characters and bounded")
    func labelNormalization() {
        #expect(DeviceLabel.normalized("iPhone\u{0}\u{7} 16") == "iPhone 16")
        #expect(DeviceLabel.normalized("  spaced   out  ") == "spaced out")
        #expect(DeviceLabel.normalized("") == "Unnamed device")
        #expect(DeviceLabel.normalized("\n\t") == "Unnamed device")
        #expect(DeviceLabel.normalized(String(repeating: "x", count: 200)).count == DeviceLabel.maximumLength)
    }

    @Test("display name always carries the fingerprint, so labels cannot impersonate")
    func displayNameIncludesFingerprint() {
        let device = AuthorizedDevice(
            fingerprint: makeFingerprint(0xCD),
            label: "iPhone 16",
            createdAt: Date(),
            lastSeenAt: Date()
        )
        #expect(device.displayName.contains("iPhone 16"))
        #expect(device.displayName.contains(device.fingerprint.shortForm))
    }

    @Test("only well-formed digests parse as fingerprints")
    func fingerprintValidation() {
        #expect(DeviceFingerprint(hex: String(repeating: "a", count: 64)) != nil)
        #expect(DeviceFingerprint(hex: String(repeating: "A", count: 64)) != nil)
        #expect(DeviceFingerprint(hex: String(repeating: "a", count: 63)) == nil)
        #expect(DeviceFingerprint(hex: String(repeating: "z", count: 64)) == nil)
        #expect(DeviceFingerprint(hex: "") == nil)
    }

    @Test("a generated identity yields a stable fingerprint over its certificate")
    func identityFingerprintMatchesCertificate() throws {
        let identity = try DeviceIdentityMaterial.generate()
        let recomputed = DeviceFingerprint(derEncodedCertificate: identity.derEncodedCertificate)
        #expect(recomputed == identity.fingerprint)

        let rehydrated = try DeviceIdentityMaterial(
            pemPrivateKey: identity.pemPrivateKey,
            derEncodedCertificate: identity.derEncodedCertificate
        )
        #expect(rehydrated.fingerprint == identity.fingerprint)
    }

    @Test("distinct identities never collide")
    func identitiesAreDistinct() throws {
        let a = try DeviceIdentityMaterial.generate()
        let b = try DeviceIdentityMaterial.generate()
        #expect(a.fingerprint != b.fingerprint)
    }

    @Test("malformed stored identity material throws rather than silently regenerating")
    func malformedIdentityThrows() throws {
        let identity = try DeviceIdentityMaterial.generate()
        #expect(throws: DeviceIdentityError.malformedPrivateKey) {
            _ = try DeviceIdentityMaterial(
                pemPrivateKey: "not a key",
                derEncodedCertificate: identity.derEncodedCertificate
            )
        }
        #expect(throws: DeviceIdentityError.malformedCertificate) {
            _ = try DeviceIdentityMaterial(
                pemPrivateKey: identity.pemPrivateKey,
                derEncodedCertificate: Data("not a certificate".utf8)
            )
        }
    }

    @Test("enrollment tickets are unique and expire")
    func ticketProperties() throws {
        let start = Date()
        let first = try EnrollmentTicket.mint(now: start)
        let second = try EnrollmentTicket.mint(now: start)
        #expect(first.secret != second.secret)
        #expect(first.secret.count >= 40)
        #expect(first.isRedeemable(at: start))
        #expect(first.isRedeemable(at: start.addingTimeInterval(EnrollmentTicket.defaultLifetime + 1)) == false)
    }
}

/// Minimal mutex so tests can capture callback output without importing more.
private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
