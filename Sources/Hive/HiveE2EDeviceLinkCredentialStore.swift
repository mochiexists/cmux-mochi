#if DEBUG
import CmuxMobileShell
import DeviceLinkKit
import os

/// Process-local DeviceLink credentials for the explicit headless Hive harness.
///
/// The synchronous credential protocols are called from Network.framework TLS
/// callbacks, so this short critical section cannot be actor-isolated.
final class HiveE2EDeviceLinkCredentialStore:
    MobileDeviceIdentityStoring,
    MobileServerPinStoring,
    @unchecked Sendable
{
    private struct State: Sendable {
        var identities: [String: DeviceIdentityMaterial] = [:]
        var pins: [String: DeviceFingerprint] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func identity(forPairingID pairingID: String) throws -> DeviceIdentityMaterial? {
        state.withLock { $0.identities[pairingID] }
    }

    func save(_ material: DeviceIdentityMaterial, forPairingID pairingID: String) throws {
        state.withLock { $0.identities[pairingID] = material }
    }

    func remove(pairingID: String) throws {
        state.withLock { $0.identities[pairingID] = nil }
    }

    func pins() throws -> [String: DeviceFingerprint] {
        state.withLock { $0.pins }
    }

    func setPin(_ fingerprint: DeviceFingerprint, forPairingID pairingID: String) throws {
        state.withLock { $0.pins[pairingID] = fingerprint }
    }

    func removePin(forPairingID pairingID: String) throws {
        state.withLock { $0.pins[pairingID] = nil }
    }
}
#endif
