import CMUXMobileCore
import DeviceLinkKit
import Foundation

extension MobileHostDeviceLink {
    /// Builds the pairing payload a QR code (or a typed manual entry) carries.
    ///
    /// Fork (cmux Mochi): the v3 grammar carries **no bearer credential**. It
    /// carries routes, this Mac's public-key fingerprint (so the phone
    /// authenticates the Mac from the first byte, with no trust-on-first-use
    /// window), and a single-use enrollment ticket whose only power is to add
    /// one public key to the authorized-devices table — an act that notifies the
    /// operator and is individually revocable.
    ///
    /// The previous grammar put a working auth token in the QR, so a
    /// photographed code was usable for the token's whole lifetime.
    func makePairingPayload(
        scheme: String = CmxPairingURLScheme.current,
        lifetime: TimeInterval = EnrollmentTicket.defaultLifetime
    ) async throws -> PairingPayload {
        await prepare()
        guard let fingerprint = hostFingerprint() else {
            throw MobileHostDeviceLinkPairingError.identityUnavailable
        }
        let ticket = try await issueEnrollmentTicket(lifetime: lifetime)
        let routes = MobileHostPublicStatusCache.snapshot()
            .compactMap(Self.routeDescription)
        guard !routes.isEmpty else {
            throw MobileHostDeviceLinkPairingError.noRoutes
        }
        return PairingPayload(
            scheme: scheme,
            routes: routes,
            macFingerprint: fingerprint,
            enrollmentTicket: ticket.secret,
            macLabel: MobileHostIdentity.instanceDisplayName()
        )
    }

    /// Renders a pairing payload as the deep link a QR encodes.
    func makePairingURL(
        scheme: String = CmxPairingURLScheme.current,
        lifetime: TimeInterval = EnrollmentTicket.defaultLifetime
    ) async throws -> URL {
        let payload = try await makePairingPayload(scheme: scheme, lifetime: lifetime)
        guard let url = PairingPayloadCoder.encode(payload) else {
            throw MobileHostDeviceLinkPairingError.encodingFailed
        }
        return url
    }

    /// Formats a route as `host:port`, skipping anything that is not a
    /// dialable endpoint (Iroh peers advertise identities, not addresses, and
    /// DeviceLink is Tailscale-only by design).
    private static func routeDescription(_ route: CmxAttachRoute) -> String? {
        guard case let .hostPort(host, port) = route.endpoint else { return nil }
        guard route.kind == .tailscale || route.kind == .debugLoopback else { return nil }
        return "\(host):\(port)"
    }
}

enum MobileHostDeviceLinkPairingError: Error, Equatable {
    /// This Mac has no TLS identity, so it cannot be pinned by a phone.
    case identityUnavailable
    /// No dialable route is published yet — usually Tailscale still coming up.
    case noRoutes
    /// The payload could not be expressed as a URL.
    case encodingFailed
}
