import Foundation
import DeviceLinkKit
import CmuxMobileShell
import Testing
@testable import CmuxHive

@MainActor
@Suite("Hive composition")
struct HiveCompositionTests {
    @Test("builds an account-free DeviceLink workspace owner")
    func buildsCoordinator() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("hive.sqlite3")
        let defaults = try #require(
            UserDefaults(suiteName: "HiveCompositionTests-\(UUID().uuidString)")
        )
        let credentials = InMemoryHiveDeviceLinkStore()
        let client = MobileDeviceLinkClient(
            identityStore: credentials,
            pinStore: credentials,
            pairingIndexDefaults: defaults
        )

        let composition = try HiveComposition(
            databaseURL: databaseURL,
            defaults: defaults,
            deviceLinkClient: client
        )

        #expect(composition.coordinator.phase == .idle)
        #expect(!composition.shell.isSignedIn)
        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
    }
}

private final class InMemoryHiveDeviceLinkStore:
    MobileDeviceIdentityStoring,
    MobileServerPinStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var identities: [String: DeviceIdentityMaterial] = [:]
    private var storedPins: [String: DeviceFingerprint] = [:]

    func identity(forPairingID pairingID: String) throws -> DeviceIdentityMaterial? {
        lock.withLock { identities[pairingID] }
    }

    func save(_ material: DeviceIdentityMaterial, forPairingID pairingID: String) throws {
        lock.withLock { identities[pairingID] = material }
    }

    func remove(pairingID: String) throws {
        lock.withLock { identities[pairingID] = nil }
    }

    func pins() throws -> [String: DeviceFingerprint] {
        lock.withLock { storedPins }
    }

    func setPin(_ fingerprint: DeviceFingerprint, forPairingID pairingID: String) throws {
        lock.withLock { storedPins[pairingID] = fingerprint }
    }

    func removePin(forPairingID pairingID: String) throws {
        lock.withLock { storedPins[pairingID] = nil }
    }
}
