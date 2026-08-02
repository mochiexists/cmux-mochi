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
public enum SecIdentityFactory {
    public enum FactoryError: Error, Equatable {
        case keyImportFailed(OSStatus)
        case certificateRejected
        case identityLookupFailed(OSStatus)
        case identityNotFound
        case malformedKey
    }

    /// Imports identity material and returns the matching `SecIdentity`.
    ///
    /// Idempotent: re-importing material that is already present resolves to
    /// the existing identity rather than duplicating it.
    ///
    /// - Parameters:
    ///   - material: The generated key and certificate.
    ///   - label: Keychain label for the certificate, so instances of this app
    ///     can find (and clean up) their own items.
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

        if let existing = try? lookupIdentity(matching: material.derEncodedCertificate) {
            return existing
        }

        guard let privateKey = try? P256.Signing.PrivateKey(pemRepresentation: material.pemPrivateKey) else {
            throw FactoryError.malformedKey
        }
        let keyAttributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var keyError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(
            privateKey.x963Representation as CFData,
            keyAttributes as CFDictionary,
            &keyError
        ) else {
            throw FactoryError.keyImportFailed(errSecParam)
        }

        // Data-protection keychain first; on macOS a locally signed build lacks
        // the entitlement it requires, so fall back to the file keychain rather
        // than leaving development unable to pair at all.
        var lastStatus = errSecSuccess
        for useDataProtection in Self.keychainPreferenceOrder {
            var keyAdd: [CFString: Any] = [
                kSecClass: kSecClassKey,
                kSecValueRef: secKey,
                kSecAttrApplicationTag: Data(material.fingerprint.hex.utf8),
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            var certificateAdd: [CFString: Any] = [
                kSecClass: kSecClassCertificate,
                kSecValueRef: certificate,
                kSecAttrLabel: label,
            ]
            keyAdd[kSecUseDataProtectionKeychain] = useDataProtection
            certificateAdd[kSecUseDataProtectionKeychain] = useDataProtection

            let keyStatus = SecItemAdd(keyAdd as CFDictionary, nil)
            guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
                lastStatus = keyStatus
                continue
            }
            let certificateStatus = SecItemAdd(certificateAdd as CFDictionary, nil)
            guard certificateStatus == errSecSuccess || certificateStatus == errSecDuplicateItem else {
                lastStatus = certificateStatus
                continue
            }
            if let identity = try? lookupIdentity(matching: material.derEncodedCertificate) {
                return identity
            }
        }
        throw FactoryError.keyImportFailed(lastStatus)
    }

    /// Removes the keychain items backing an identity — used when a pairing is
    /// forgotten, so a device's key does not outlive its purpose.
    public static func removeIdentity(for material: DeviceIdentityMaterial) {
        let keyQuery: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Data(material.fingerprint.hex.utf8),
            kSecUseDataProtectionKeychain: true,
        ]
        SecItemDelete(keyQuery as CFDictionary)

        if let certificate = SecCertificateCreateWithData(nil, material.derEncodedCertificate as CFData) {
            let certificateQuery: [CFString: Any] = [
                kSecClass: kSecClassCertificate,
                kSecValueRef: certificate,
                kSecUseDataProtectionKeychain: true,
            ]
            SecItemDelete(certificateQuery as CFDictionary)
        }
    }

    /// Which keychains to try, in order. iOS has only one.
    static var keychainPreferenceOrder: [Bool] {
        #if os(iOS)
        [true]
        #else
        [true, false]
        #endif
    }

    private static func lookupIdentity(matching certificateDER: Data) throws -> SecIdentity {
        var identities: [SecIdentity] = []
        for useDataProtection in keychainPreferenceOrder {
            var query: [CFString: Any] = [
                kSecClass: kSecClassIdentity,
                kSecReturnRef: true,
                kSecMatchLimit: kSecMatchLimitAll,
            ]
            query[kSecUseDataProtectionKeychain] = useDataProtection
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let found = result as? [SecIdentity] {
                identities.append(contentsOf: found)
            }
        }
        guard !identities.isEmpty else {
            throw FactoryError.identityNotFound
        }
        for identity in identities {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate
            else { continue }
            if SecCertificateCopyData(certificate) as Data == certificateDER {
                return identity
            }
        }
        throw FactoryError.identityNotFound
    }
}
