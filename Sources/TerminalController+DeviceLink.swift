import DeviceLinkKit
import Foundation

// MARK: - DeviceLink pairing management (local control socket only)

extension TerminalController {
    /// Lists the devices paired with this Mac.
    ///
    /// Fork (cmux Mochi): reachable only over the local automation socket —
    /// whoever can speak to that socket already controls this Mac. Exposing it
    /// on the network path would let a paired phone enumerate (and, with
    /// revoke, evict) its siblings.
    @MainActor
    func v2DeviceLinkDeviceList() async -> V2CallResult {
        let devices = await MobileHostDeviceLink.shared.devices()
        let formatter = ISO8601DateFormatter()
        let payload: [[String: Any]] = devices.map { device in
            [
                "fingerprint": device.fingerprint.hex,
                "fingerprint_short": device.fingerprint.shortForm,
                "label": device.label,
                "display_name": device.displayName,
                "created_at": formatter.string(from: device.createdAt),
                "last_seen_at": formatter.string(from: device.lastSeenAt),
            ]
        }
        return .ok(["devices": payload])
    }

    /// Revokes one paired device and drops its live connections.
    ///
    /// Revocation is per device: the other pairings on this Mac keep working,
    /// which is the property a shared bearer credential could never offer.
    @MainActor
    func v2DeviceLinkDeviceRevoke(params: [String: Any]) async -> V2CallResult {
        guard let raw = v2OptionalTrimmedRawString(params, "fingerprint"), !raw.isEmpty else {
            return .err(
                code: "invalid_request",
                message: "fingerprint is required",
                data: nil
            )
        }
        guard DeviceFingerprint(hex: raw) != nil else {
            return .err(
                code: "invalid_request",
                message: "fingerprint must be a 64-character SHA-256 digest",
                data: nil
            )
        }
        do {
            let didRevoke = try await MobileHostDeviceLink.shared.revoke(fingerprintHex: raw)
            return .ok(["revoked": didRevoke])
        } catch {
            return .err(
                code: "internal_error",
                message: "Revocation could not be saved.",
                data: nil
            )
        }
    }
}
