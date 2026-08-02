public import Foundation

/// One row in a Mac's authorized-devices table — the DeviceLink analogue of a
/// line in `authorized_keys`.
///
/// The row holds no secret: a fingerprint names a public key, and the label is
/// operator-facing text. Confidentiality is therefore a nicety (device names
/// are mildly private); **integrity is the requirement**, since anyone who can
/// write this table can authorize themselves.
public struct AuthorizedDevice: Sendable, Codable, Equatable, Identifiable {
    /// The device's public-key identity. Also the row's primary key.
    public let fingerprint: DeviceFingerprint
    /// Operator-supplied name, normalized by ``DeviceLabel``.
    public var label: String
    /// When this device was enrolled.
    public let createdAt: Date
    /// When this device last completed an admitted handshake.
    public var lastSeenAt: Date

    public var id: String { fingerprint.hex }

    /// A display form that never lets an attacker-chosen label impersonate
    /// another device: the label always travels with its fingerprint prefix.
    public var displayName: String {
        "\(label) (\(fingerprint.shortForm))"
    }

    public init(
        fingerprint: DeviceFingerprint,
        label: String,
        createdAt: Date,
        lastSeenAt: Date
    ) {
        self.fingerprint = fingerprint
        self.label = label
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }
}

/// Normalization for device labels, which arrive from the peer and are
/// therefore untrusted input rendered into notifications and CLI output.
public enum DeviceLabel {
    /// Maximum stored length in Unicode scalars.
    public static let maximumLength = 64

    /// Strips control characters, collapses whitespace, and bounds the length.
    /// - Parameter raw: The label as supplied by the enrolling device.
    /// - Returns: A safe label, or a generic placeholder when nothing survives.
    public static func normalized(_ raw: String) -> String {
        let stripped = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        let collapsed = stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "Unnamed device" }
        return String(collapsed.prefix(maximumLength))
    }
}

/// A versioned envelope so a future schema change is a migration rather than a
/// corrupt-file incident.
///
/// An unknown version or unparseable payload is treated as an **empty** table:
/// every device must re-pair, which is recoverable and obvious, rather than the
/// alternative of guessing at half-understood rows.
public struct AuthorizedDeviceTable: Sendable, Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var devices: [AuthorizedDevice]

    public init(version: Int = AuthorizedDeviceTable.currentVersion, devices: [AuthorizedDevice] = []) {
        self.version = version
        self.devices = devices
    }

    /// Decodes a table, returning an empty one for anything unrecognizable.
    /// - Parameter data: Serialized table bytes, or `nil` when absent.
    /// - Returns: The decoded table and whether the input was rejected, so the
    ///   caller can log loudly (silent data loss is worse than re-pairing).
    public static func decode(_ data: Data?) -> (table: AuthorizedDeviceTable, wasRejected: Bool) {
        guard let data, !data.isEmpty else { return (AuthorizedDeviceTable(), false) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(AuthorizedDeviceTable.self, from: data) else {
            return (AuthorizedDeviceTable(), true)
        }
        guard decoded.version == AuthorizedDeviceTable.currentVersion else {
            return (AuthorizedDeviceTable(), true)
        }
        return (decoded, false)
    }

    /// Serializes the table for the platform keystore.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
