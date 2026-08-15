public import Foundation
internal import CryptoKit

/// Builds the one X.509 profile DeviceLink uses: a self-signed P-256 leaf whose
/// only job is to carry a public key into a TLS handshake.
///
/// Nothing here validates chains or names, because DeviceLink never does: a
/// peer is identified by the SHA-256 of its SubjectPublicKeyInfo, and the
/// certificate is the envelope that gets it there.
enum SelfSignedCertificate {
    /// Encodes the SubjectPublicKeyInfo for a P-256 public key.
    ///
    /// This is the exact byte sequence a fingerprint is taken over, so its
    /// stability *is* the identity's stability.
    static func subjectPublicKeyInfo(for publicKey: P256.Signing.PublicKey) -> [UInt8] {
        DER.sequence([
            DER.sequence([
                DER.objectIdentifier(OID.ecPublicKey),
                DER.objectIdentifier(OID.prime256v1),
            ]),
            DER.bitString(Array(publicKey.x963Representation)),
        ])
    }

    /// Builds and signs a self-signed certificate.
    ///
    /// - Parameters:
    ///   - key: The subject's (and issuer's) private key.
    ///   - commonName: Subject and issuer common name.
    ///   - notBefore: Start of validity.
    ///   - notAfter: End of validity. DeviceLink sets this far out on purpose:
    ///     revocation is the authorized-devices table, not expiry, and a
    ///     certificate that lapsed would strand a paired device with no
    ///     recovery except re-scanning.
    ///   - serialNumber: Big-endian serial bytes.
    /// - Returns: DER bytes of the finished certificate.
    static func make(
        key: P256.Signing.PrivateKey,
        commonName: String,
        notBefore: Date,
        notAfter: Date,
        serialNumber: [UInt8]
    ) throws -> Data {
        let name = DER.sequence([
            DER.set([
                DER.sequence([
                    DER.objectIdentifier(OID.commonName),
                    DER.encode(.utf8String, Array(commonName.utf8)),
                ]),
            ]),
        ])

        let signatureAlgorithm = DER.sequence([DER.objectIdentifier(OID.ecdsaWithSHA256)])

        // Critical: this is an end-entity certificate, and it may act as both
        // TLS client and server — a phone is a client, a Mac is a server, and
        // the same builder produces both.
        let extensions = DER.contextConstructed(3, DER.sequence([
            DER.sequence([
                DER.objectIdentifier(OID.basicConstraints),
                DER.encode(.boolean, [0xFF]),
                DER.encode(.octetString, DER.sequence([])),
            ]),
            DER.sequence([
                DER.objectIdentifier(OID.keyUsage),
                DER.encode(.boolean, [0xFF]),
                // digitalSignature only: this key signs handshakes, nothing else.
                DER.encode(.octetString, DER.encode(.bitString, [0x07, 0x80])),
            ]),
            DER.sequence([
                DER.objectIdentifier(OID.extendedKeyUsage),
                DER.encode(.octetString, DER.sequence([
                    DER.objectIdentifier(OID.serverAuth),
                    DER.objectIdentifier(OID.clientAuth),
                ])),
            ]),
        ]))

        let tbsCertificate = DER.sequence([
            DER.contextConstructed(0, DER.integer(2)), // v3
            DER.integer(serialNumber),
            signatureAlgorithm,
            name,
            DER.sequence([DER.time(notBefore), DER.time(notAfter)]),
            name,
            subjectPublicKeyInfo(for: key.publicKey),
            extensions,
        ])

        let signature = try key.signature(for: Data(tbsCertificate))
        return Data(DER.sequence([
            tbsCertificate,
            signatureAlgorithm,
            DER.bitString(Array(signature.derRepresentation)),
        ]))
    }

    /// Extracts the SubjectPublicKeyInfo from a DER certificate.
    ///
    /// Walks the structure positionally rather than parsing generally: the
    /// profile is fixed, and a certificate that does not match it is one
    /// DeviceLink did not issue.
    static func subjectPublicKeyInfo(fromCertificate der: Data) -> Data? {
        var reader = DERReader(bytes: Array(der))
        guard let certificate = reader.readSequenceContents() else { return nil }
        var tbsReader = DERReader(bytes: certificate)
        guard let tbs = tbsReader.readSequenceContents() else { return nil }
        var body = DERReader(bytes: tbs)

        // tbsCertificate fields, in order, up to subjectPublicKeyInfo.
        guard body.skipElement() else { return nil }        // [0] version
        guard body.skipElement() else { return nil }        // serialNumber
        guard body.skipElement() else { return nil }        // signature algorithm
        guard body.skipElement() else { return nil }        // issuer
        guard body.skipElement() else { return nil }        // validity
        guard body.skipElement() else { return nil }        // subject
        guard let spki = body.readElement() else { return nil }
        return Data(spki)
    }
}

/// Positional reader for the fixed certificate profile above.
private struct DERReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Returns the contents of a top-level SEQUENCE.
    mutating func readSequenceContents() -> [UInt8]? {
        guard let element = readElementParts(), element.tag == DER.Tag.sequence.rawValue else { return nil }
        return Array(bytes[element.contentRange])
    }

    /// Returns a whole element including its tag and length bytes.
    mutating func readElement() -> [UInt8]? {
        guard let element = readElementParts() else { return nil }
        return Array(bytes[element.fullRange])
    }

    mutating func skipElement() -> Bool {
        readElementParts() != nil
    }

    private mutating func readElementParts() -> (tag: UInt8, fullRange: Range<Int>, contentRange: Range<Int>)? {
        guard offset < bytes.count else { return nil }
        let start = offset
        let tag = bytes[offset]
        offset += 1
        guard offset < bytes.count else { return nil }

        var length = 0
        let first = bytes[offset]
        offset += 1
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard count > 0, offset + count <= bytes.count else { return nil }
            for _ in 0 ..< count {
                length = (length << 8) | Int(bytes[offset])
                offset += 1
            }
        }
        guard offset + length <= bytes.count else { return nil }
        let contentStart = offset
        offset += length
        return (tag, start ..< offset, contentStart ..< (contentStart + length))
    }
}
