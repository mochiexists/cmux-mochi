import Foundation

/// A minimal DER writer — just enough to build one shape of X.509 certificate.
///
/// DeviceLink needs exactly one certificate profile: a self-signed P-256 leaf
/// that carries a public key. Rather than take a general-purpose ASN.1
/// dependency (and its vendored crypto, which collides with this app's own),
/// the few structures involved are written directly. Everything here is
/// exercised by ``DeviceIdentityMaterial`` round-trips and, more strictly, by
/// the TLS loopback tests: a malformed encoding is rejected outright by
/// `SecCertificateCreateWithData` and by the TLS handshake.
enum DER {
    enum Tag: UInt8 {
        case boolean = 0x01
        case integer = 0x02
        case bitString = 0x03
        case octetString = 0x04
        case null = 0x05
        case objectIdentifier = 0x06
        case utf8String = 0x0C
        case printableString = 0x13
        case utcTime = 0x17
        case generalizedTime = 0x18
        case sequence = 0x30
        case set = 0x31
    }

    /// Wraps `contents` in a tag-length-value triple.
    static func encode(_ tag: UInt8, _ contents: [UInt8]) -> [UInt8] {
        [tag] + length(contents.count) + contents
    }

    static func encode(_ tag: Tag, _ contents: [UInt8]) -> [UInt8] {
        encode(tag.rawValue, contents)
    }

    /// Context-specific constructed tag, e.g. `[0]` for the version field.
    static func contextConstructed(_ number: UInt8, _ contents: [UInt8]) -> [UInt8] {
        encode(0xA0 | number, contents)
    }

    static func sequence(_ elements: [[UInt8]]) -> [UInt8] {
        encode(.sequence, elements.flatMap { $0 })
    }

    static func set(_ elements: [[UInt8]]) -> [UInt8] {
        encode(.set, elements.flatMap { $0 })
    }

    /// Encodes a non-negative integer, adding the leading zero DER requires
    /// when the high bit would otherwise mark it negative.
    static func integer(_ value: [UInt8]) -> [UInt8] {
        var bytes = value
        while bytes.count > 1, bytes[0] == 0x00, bytes[1] & 0x80 == 0 {
            bytes.removeFirst()
        }
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        if bytes.isEmpty { bytes = [0x00] }
        return encode(.integer, bytes)
    }

    static func integer(_ value: Int) -> [UInt8] {
        var magnitude = UInt64(abs(value))
        var bytes: [UInt8] = []
        repeat {
            bytes.insert(UInt8(magnitude & 0xFF), at: 0)
            magnitude >>= 8
        } while magnitude > 0
        return integer(bytes)
    }

    /// Encodes a bit string with no unused trailing bits.
    static func bitString(_ contents: [UInt8]) -> [UInt8] {
        encode(.bitString, [0x00] + contents)
    }

    /// Encodes an OID from its dotted components.
    static func objectIdentifier(_ components: [UInt] ) -> [UInt8] {
        guard components.count >= 2 else { return encode(.objectIdentifier, []) }
        var bytes: [UInt8] = [UInt8(components[0] * 40 + components[1])]
        for component in components.dropFirst(2) {
            bytes += base128(component)
        }
        return encode(.objectIdentifier, bytes)
    }

    /// UTCTime for years 1950–2049, which is what X.509 mandates in that range.
    static func utcTime(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let text = String(
            format: "%02d%02d%02d%02d%02d%02dZ",
            (parts.year ?? 2000) % 100,
            parts.month ?? 1,
            parts.day ?? 1,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
        return encode(.utcTime, Array(text.utf8))
    }

    /// GeneralizedTime, required for years from 2050 onward.
    static func generalizedTime(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let text = String(
            format: "%04d%02d%02d%02d%02d%02dZ",
            parts.year ?? 2000,
            parts.month ?? 1,
            parts.day ?? 1,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
        return encode(.generalizedTime, Array(text.utf8))
    }

    /// Picks the time encoding X.509 requires for a given year.
    static func time(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let year = calendar.component(.year, from: date)
        return (1950 ... 2049).contains(year) ? utcTime(date) : generalizedTime(date)
    }

    private static func length(_ value: Int) -> [UInt8] {
        if value < 0x80 { return [UInt8(value)] }
        var bytes: [UInt8] = []
        var remaining = value
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private static func base128(_ value: UInt) -> [UInt8] {
        if value == 0 { return [0x00] }
        var bytes: [UInt8] = []
        var remaining = value
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0x7F), at: 0)
            remaining >>= 7
        }
        for index in 0 ..< (bytes.count - 1) {
            bytes[index] |= 0x80
        }
        return bytes
    }
}

/// The object identifiers this profile needs.
enum OID {
    /// ecPublicKey
    static let ecPublicKey: [UInt] = [1, 2, 840, 10045, 2, 1]
    /// prime256v1 / P-256
    static let prime256v1: [UInt] = [1, 2, 840, 10045, 3, 1, 7]
    /// ecdsa-with-SHA256
    static let ecdsaWithSHA256: [UInt] = [1, 2, 840, 10045, 4, 3, 2]
    /// id-at-commonName
    static let commonName: [UInt] = [2, 5, 4, 3]
    /// id-ce-basicConstraints
    static let basicConstraints: [UInt] = [2, 5, 29, 19]
    /// id-ce-keyUsage
    static let keyUsage: [UInt] = [2, 5, 29, 15]
    /// id-ce-extKeyUsage
    static let extendedKeyUsage: [UInt] = [2, 5, 29, 37]
    /// id-kp-serverAuth
    static let serverAuth: [UInt] = [1, 3, 6, 1, 5, 5, 7, 3, 1]
    /// id-kp-clientAuth
    static let clientAuth: [UInt] = [1, 3, 6, 1, 5, 5, 7, 3, 2]
}
