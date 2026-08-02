public import Foundation
public import Network
internal import Security

/// Builds the Network.framework TLS options for a DeviceLink connection.
///
/// DeviceLink authenticates *keys*, not names: verification is a fingerprint
/// comparison against a pin (client side) or the authorized-devices table
/// (server side). There is no chain building, no trust store, and no hostname
/// check, because a self-signed certificate here is a key carrier and nothing
/// more.
///
/// The host app supplies the `SecIdentity`; this package never touches the
/// keychain, so it stays free of entitlement assumptions and remains testable
/// with ephemeral identities.
///
/// ## Why TLS options rather than a byte-stream wrapper
///
/// TLS must be configured when the `NWConnection`/`NWListener` is *created*.
/// These factories therefore hand back parameters for the transport layer to
/// construct with, rather than trying to wrap an already-open stream.
public enum DeviceLinkTLS {
    /// The only application protocol DeviceLink speaks. Both ends advertise it
    /// and the client verifies the negotiated value, so this endpoint can never
    /// be confused with another protocol sharing a port.
    public static let applicationProtocol = "cmux-devicelink/1"

    /// Options for the Mac's listener.
    ///
    /// - Parameters:
    ///   - identity: The Mac's own TLS identity.
    ///   - authorize: Called with each client's fingerprint; returns whether to
    ///     admit. The host routes this to ``DeviceLinkCoordinator`` so table
    ///     reads and revocations are ordered by one actor.
    /// - Returns: TLS 1.3-only options requiring a client certificate.
    public static func listenerOptions(
        identity: SecIdentity,
        authorize: @escaping @Sendable (DeviceFingerprint) -> Bool
    ) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        applyCommon(security, identity: identity)
        // Servers default to NOT requiring a client certificate; DeviceLink's
        // whole model depends on requiring one.
        sec_protocol_options_set_peer_authentication_required(security, true)
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            guard let fingerprint = leafFingerprint(from: trust) else {
                complete(false)
                return
            }
            complete(authorize(fingerprint))
        }, verificationQueue)
        return options
    }

    /// Options for the phone's connection.
    ///
    /// - Parameters:
    ///   - identity: This device's own TLS identity.
    ///   - expectedServerFingerprint: The Mac's pin, learned from the pairing
    ///     QR. Verification happens before any application data is sent, so an
    ///     impostor squatting the port learns nothing.
    /// - Returns: TLS 1.3-only options pinned to that server key.
    public static func connectionOptions(
        identity: SecIdentity,
        expectedServerFingerprint: DeviceFingerprint
    ) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        applyCommon(security, identity: identity)
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            guard let fingerprint = leafFingerprint(from: trust) else {
                complete(false)
                return
            }
            complete(fingerprint == expectedServerFingerprint)
        }, verificationQueue)
        return options
    }

    /// Reads the ALPN value actually negotiated on a ready connection.
    ///
    /// Advertising a protocol is not the same as negotiating it; callers verify
    /// this equals ``applicationProtocol`` before trusting the channel.
    public static func negotiatedApplicationProtocol(
        from metadata: NWProtocolTLS.Metadata
    ) -> String? {
        let security = metadata.securityProtocolMetadata
        if #available(iOS 18.5, macOS 15.5, *) {
            guard let copied = sec_protocol_metadata_copy_negotiated_protocol(security) else { return nil }
            defer { free(UnsafeMutableRawPointer(mutating: copied)) }
            return String(cString: copied)
        }
        guard let raw = sec_protocol_metadata_get_negotiated_protocol(security) else { return nil }
        return String(cString: raw)
    }

    /// Extracts the peer's leaf-certificate fingerprint from a handshake trust
    /// object. Exposed so the host can label an admitted connection.
    public static func leafFingerprint(from trust: sec_trust_t) -> DeviceFingerprint? {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
              let leaf = chain.first
        else { return nil }
        return DeviceFingerprint(derEncodedCertificate: SecCertificateCopyData(leaf) as Data)
    }

    private static let verificationQueue = DispatchQueue(
        label: "dev.cmux.devicelink.tls-verify",
        qos: .userInitiated
    )

    private static func applyCommon(_ security: sec_protocol_options_t, identity: SecIdentity) {
        if let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(security, secIdentity)
        }
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_add_tls_application_protocol(security, applicationProtocol)
        // Resumption is disabled unconditionally: a resumed session would skip
        // the verify block, letting a revoked device reconnect on a cached
        // ticket. Revocation must be immediate, so there is no fast path.
        sec_protocol_options_set_tls_resumption_enabled(security, false)
        sec_protocol_options_set_tls_tickets_enabled(security, false)
    }
}
