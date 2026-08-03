import DeviceLinkKit
import Foundation

/// Lock-guarded view of which devices may be admitted right now.
///
/// Exists so the TLS verify block — which runs on a Network.framework callback
/// thread during the handshake — can answer immediately. Awaiting an actor
/// there stalls the handshake until the connect deadline, which presents as an
/// unreachable Mac rather than as an authorization problem.
final class MobileHostDeviceLinkAdmissionSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var authorized: Set<DeviceFingerprint> = []
    private var enrollmentWindowOpen = false

    /// Whether a presented key may complete the handshake.
    ///
    /// An unknown key is admitted only while an enrollment window is open, and
    /// the connection it gets is restricted to the enrollment verb.
    func admits(_ fingerprint: DeviceFingerprint) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return authorized.contains(fingerprint) || enrollmentWindowOpen
    }

    func update(authorized: Set<DeviceFingerprint>, enrollmentWindowOpen: Bool) {
        lock.lock()
        self.authorized = authorized
        self.enrollmentWindowOpen = enrollmentWindowOpen
        lock.unlock()
    }
}
