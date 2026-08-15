public import Foundation
internal import CryptoKit

/// The canonical identity of a device in a DeviceLink pairing: the SHA-256
/// digest of its certificate's DER-encoded SubjectPublicKeyInfo.
///
/// A fingerprint names a *public key*, not a certificate, so re-issuing a
/// certificate around the same key preserves the pairing. It is the only
/// identity DeviceLink compares — no chain building, no trust store, no
/// hostname matching (see ``DeviceLinkTLS``).
public struct DeviceFingerprint: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Lowercase hexadecimal SHA-256 of the DER SubjectPublicKeyInfo.
    public let hex: String

    /// Wraps an already-canonical fingerprint string.
    /// - Parameter hex: 64 lowercase hex characters.
    /// - Returns: `nil` when the input is not a well-formed SHA-256 digest.
    public init?(hex: String) {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 64,
              normalized.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
        else { return nil }
        self.hex = normalized
    }

    /// Computes the fingerprint of a DER-encoded X.509 certificate.
    /// - Parameter derEncodedCertificate: The certificate's DER bytes.
    /// - Returns: `nil` when the bytes are not a parseable certificate.
    public init?(derEncodedCertificate: Data) {
        guard let spki = SelfSignedCertificate.subjectPublicKeyInfo(fromCertificate: derEncodedCertificate) else {
            return nil
        }
        self.hex = SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined()
    }

    /// Fingerprint of a public key directly, for a key not yet wrapped in a
    /// certificate.
    init(publicKey: P256.Signing.PublicKey) {
        let spki = Data(SelfSignedCertificate.subjectPublicKeyInfo(for: publicKey))
        self.hex = SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined()
    }

    /// A short, human-readable form for notifications and CLI output.
    ///
    /// Device labels are attacker-supplied, so anything that shows a label to
    /// the operator shows this alongside it.
    public var shortForm: String {
        String(hex.prefix(12))
    }

    public var description: String { hex }
}
