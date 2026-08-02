public import Foundation
internal import CryptoKit

/// Errors raised while creating or loading a device identity.
public enum DeviceIdentityError: Error, Equatable {
    /// The platform CSPRNG or certificate builder failed. DeviceLink fails
    /// closed here: a device identity is never derived from a weaker source.
    case identityGenerationFailed(String)
    /// The DER bytes handed to ``DeviceIdentityMaterial/init(pemPrivateKey:derEncodedCertificate:)``
    /// did not parse as an X.509 certificate.
    case malformedCertificate
    /// The stored private key could not be decoded.
    case malformedPrivateKey
}

/// A device's own key pair plus the self-signed certificate that carries it.
///
/// The private key never leaves the device that generated it, never transits
/// the network, and is never known to a peer — a peer only ever learns the
/// ``DeviceFingerprint``. This is the SSH `authorized_keys` model: possession
/// of the key *is* the credential, and pairing is an exchange of public
/// identities rather than the issuance of a secret.
public struct DeviceIdentityMaterial: Sendable {
    /// PEM-encoded P-256 private key. Persist only in the platform keystore.
    public let pemPrivateKey: String
    /// DER-encoded self-signed X.509 certificate wrapping the public key.
    public let derEncodedCertificate: Data
    /// The identity's canonical fingerprint.
    public let fingerprint: DeviceFingerprint

    /// Rehydrates identity material previously persisted by the caller.
    /// - Parameters:
    ///   - pemPrivateKey: The PEM private key as returned by ``pemPrivateKey``.
    ///   - derEncodedCertificate: The certificate bytes as returned by ``derEncodedCertificate``.
    /// - Throws: ``DeviceIdentityError/malformedPrivateKey`` or
    ///   ``DeviceIdentityError/malformedCertificate`` when the stored bytes do
    ///   not round-trip. Callers treat a throw as "re-pair required", never as
    ///   a reason to silently mint a replacement identity.
    public init(pemPrivateKey: String, derEncodedCertificate: Data) throws {
        guard (try? P256.Signing.PrivateKey(pemRepresentation: pemPrivateKey)) != nil else {
            throw DeviceIdentityError.malformedPrivateKey
        }
        guard let fingerprint = DeviceFingerprint(derEncodedCertificate: derEncodedCertificate) else {
            throw DeviceIdentityError.malformedCertificate
        }
        self.pemPrivateKey = pemPrivateKey
        self.derEncodedCertificate = derEncodedCertificate
        self.fingerprint = fingerprint
    }

    private init(pemPrivateKey: String, derEncodedCertificate: Data, fingerprint: DeviceFingerprint) {
        self.pemPrivateKey = pemPrivateKey
        self.derEncodedCertificate = derEncodedCertificate
        self.fingerprint = fingerprint
    }

    /// Generates a fresh P-256 identity and its self-signed certificate.
    ///
    /// The certificate's validity is deliberately long: expiry is **not** the
    /// revocation mechanism in DeviceLink — the authorized-devices table is
    /// (see ``AuthorizedDeviceStore``). A certificate that expires would strand
    /// a paired device with no recovery path other than re-scanning, for no
    /// security gain over revocation.
    ///
    /// - Parameters:
    ///   - commonName: A non-identifying label for the certificate subject.
    ///   - validity: How long the certificate claims to be valid.
    ///   - now: Injected clock for tests.
    /// - Returns: Freshly generated identity material.
    /// - Throws: ``DeviceIdentityError/identityGenerationFailed(_:)`` if the
    ///   platform cannot produce a key or encode the certificate.
    public static func generate(
        commonName: String = "cmux-devicelink",
        validity: TimeInterval = 100 * 365 * 24 * 60 * 60,
        now: Date = Date()
    ) throws -> DeviceIdentityMaterial {
        let key = P256.Signing.PrivateKey()
        var serialNumber = [UInt8](repeating: 0, count: 16)
        var generator = SystemRandomNumberGenerator()
        for index in serialNumber.indices {
            serialNumber[index] = UInt8.random(in: UInt8.min ... UInt8.max, using: &generator)
        }

        let derEncodedCertificate: Data
        do {
            derEncodedCertificate = try SelfSignedCertificate.make(
                key: key,
                commonName: commonName,
                notBefore: now.addingTimeInterval(-60),
                notAfter: now.addingTimeInterval(validity),
                serialNumber: serialNumber
            )
        } catch {
            throw DeviceIdentityError.identityGenerationFailed("certificate: \(error)")
        }

        let fingerprint = DeviceFingerprint(publicKey: key.publicKey)

        return DeviceIdentityMaterial(
            pemPrivateKey: key.pemRepresentation,
            derEncodedCertificate: derEncodedCertificate,
            fingerprint: fingerprint
        )
    }
}
