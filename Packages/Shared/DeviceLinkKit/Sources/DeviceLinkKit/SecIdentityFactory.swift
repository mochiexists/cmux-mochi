public import Foundation
internal import CryptoKit
internal import Security

/// Turns generated ``DeviceIdentityMaterial`` into the `SecIdentity` that
/// Network.framework's TLS stack requires.
///
/// Security.framework has no public "make me a SecIdentity from these bytes"
/// call: an identity exists only as the pairing of a certificate and its
/// private key *inside* a keychain. So the material is imported once, and the
/// resulting identity is looked up by matching certificate data.
///
/// This requires an entitled process (a signed app). An unsigned command-line
/// tool gets `errSecMissingEntitlement` (-34018) — which is why the Phase 0
/// spike proved the chain via a PKCS#12 import instead, and why these paths are
/// exercised from the app targets rather than from package tests.
/// `SecIdentityCreate` pairs a certificate with a private key in memory.
///
/// Not surfaced in the Swift overlay, but a long-standing macOS export and the
/// supported way to build an identity you already hold both halves of.
@_silgen_name("SecIdentityCreate")
private func SecIdentityCreate(
    _ allocator: CFAllocator?,
    _ certificate: SecCertificate,
    _ privateKey: SecKey
) -> Unmanaged<SecIdentity>?

public enum SecIdentityFactory {
    public enum FactoryError: Error, Equatable {
        case keyImportFailed(OSStatus)
        case certificateRejected
        case identityLookupFailed(OSStatus)
        case identityNotFound
        case malformedKey
    }

    /// Builds the `SecIdentity` that Network.framework's TLS stack requires.
    ///
    /// Both halves are already in hand, so the identity is assembled directly
    /// and nothing is written to a keychain. The earlier approach — persisting
    /// the key with `kSecAttrIsPermanent` and reading the pair back — fails on
    /// macOS in a way worth recording: `SecKeyCreateWithData` returns a valid
    /// key object but does **not** persist it, so the certificate stored alone
    /// and no identity could ever form. Avoiding the keychain sidesteps that
    /// and the `application-identifier` entitlement a locally-signed build
    /// lacks, and it works identically in test harnesses.
    ///
    /// Durable material still lives in the keychain as ordinary
    /// generic-password items (see ``KeychainDeviceIdentityStore``), which need
    /// no entitlement; this call just turns it into the object TLS wants.
    ///
    /// - Parameters:
    ///   - material: The generated key and certificate.
    ///   - label: Unused; retained so call sites need not change.
    /// - Returns: An identity usable with `sec_identity_create`.
    public static func makeIdentity(
        from material: DeviceIdentityMaterial,
        label: String = "cmux-devicelink"
    ) throws -> SecIdentity {
        guard let certificate = SecCertificateCreateWithData(
            nil,
            material.derEncodedCertificate as CFData
        ) else {
            throw FactoryError.certificateRejected
        }
        guard let privateKey = try? P256.Signing.PrivateKey(pemRepresentation: material.pemPrivateKey) else {
            throw FactoryError.malformedKey
        }

        var keyError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(
            privateKey.x963Representation as CFData,
            [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            ] as CFDictionary,
            &keyError
        ) else {
            throw FactoryError.malformedKey
        }

        guard let identity = SecIdentityCreate(nil, certificate, secKey)?.takeRetainedValue() else {
            throw FactoryError.identityNotFound
        }
        return identity
    }

    /// No-op: identities are assembled on demand, so there is nothing stored to
    /// remove. Kept so forgetting a pairing reads the same at every call site.
    public static func removeIdentity(for material: DeviceIdentityMaterial) {}
}
