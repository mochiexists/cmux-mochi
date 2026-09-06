import Foundation

// MARK: - Mobile pairing-code creation (v3 PairingPayload)

extension TerminalController {
    /// Mints a v3 pairing code: a Mac fingerprint plus a single-use enrollment
    /// ticket. The payload carries no bearer token; the phone pins this Mac's
    /// TLS identity from the fingerprint and redeems the ticket over mutual TLS.
    @MainActor
    func v2MobilePairingCodeCreate(params: [String: Any]) async -> V2CallResult {
        let lifetime = TimeInterval(
            max(30, min(v2Int(params, "ttl_seconds") ?? 600, 3600))
        )

        do {
            let url = try await MobileHostDeviceLink.shared.makePairingURL(lifetime: lifetime)
            // The URL embeds a single-use enrollment ticket, so it is a
            // credential: it goes in the result body and must never be logged.
            return .ok(["pairing_url": url.absoluteString])
        } catch MobileHostDeviceLinkPairingError.identityUnavailable {
            return .err(
                code: "unavailable",
                message: "This Mac has no DeviceLink identity yet",
                data: nil
            )
        } catch MobileHostDeviceLinkPairingError.identityFailed(let reason) {
            return .err(
                code: "internal_error",
                message: "Failed to prepare the DeviceLink identity",
                data: ["error": reason]
            )
        } catch MobileHostDeviceLinkPairingError.noRoutes {
            return .err(
                code: "unavailable",
                message: "Mobile host routes are not available yet",
                data: nil
            )
        } catch MobileHostDeviceLinkPairingError.encodingFailed {
            return .err(
                code: "internal_error",
                message: "Failed to encode the pairing payload",
                data: nil
            )
        } catch {
            return .err(
                code: "internal_error",
                message: "Failed to create a mobile pairing code",
                data: ["error": String(describing: error)]
            )
        }
    }
}
