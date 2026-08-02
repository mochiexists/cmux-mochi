public import Foundation

/// Everything a device needs to pair, carried in a QR code (or typed by hand
/// for a manual host entry).
///
/// The payload is **not** a credential for the session that follows: it carries
/// the Mac's public-key fingerprint (so the phone can authenticate the Mac from
/// the first byte, with no trust-on-first-use window) plus a ten-minute
/// single-use enrollment ticket whose only power is to add one public key to
/// the authorized-devices table.
public struct PairingPayload: Sendable, Equatable {
    /// Scheme used by the pairing deep link.
    public let scheme: String
    /// Endpoints to try, in priority order, formatted `host:port`.
    public let routes: [String]
    /// The Mac's SPKI fingerprint — the pin the phone stores and verifies.
    public let macFingerprint: DeviceFingerprint
    /// Single-use enrollment capability.
    public let enrollmentTicket: String
    /// Human-readable Mac name for the pairing UI.
    public let macLabel: String?

    public init(
        scheme: String,
        routes: [String],
        macFingerprint: DeviceFingerprint,
        enrollmentTicket: String,
        macLabel: String? = nil
    ) {
        self.scheme = scheme
        self.routes = routes
        self.macFingerprint = macFingerprint
        self.enrollmentTicket = enrollmentTicket
        self.macLabel = macLabel
    }
}

/// Encodes and decodes ``PairingPayload`` as a deep-link URL.
///
/// Grammar (v3 — the DeviceLink grammar; v1/v2 carried bearer tokens and are
/// removed):
///
/// ```
/// <scheme>://pair?v=3&r=<host:port>&r=<host:port>&f=<64-hex>&t=<ticket>&n=<label>
/// ```
public enum PairingPayloadCoder {
    /// Grammar version. Distinct from the removed bearer-carrying grammars so a
    /// stale code can never be misread as a valid one.
    public static let version = 3

    public enum DecodingError: Error, Equatable {
        case notAPairingURL
        case unsupportedVersion(Int?)
        case missingFingerprint
        case missingTicket
        case missingRoutes
    }

    /// Renders a payload as a deep-link URL.
    public static func encode(_ payload: PairingPayload) -> URL? {
        var components = URLComponents()
        components.scheme = payload.scheme
        components.host = "pair"
        var items = [URLQueryItem(name: "v", value: String(version))]
        items += payload.routes.map { URLQueryItem(name: "r", value: $0) }
        items.append(URLQueryItem(name: "f", value: payload.macFingerprint.hex))
        items.append(URLQueryItem(name: "t", value: payload.enrollmentTicket))
        if let macLabel = payload.macLabel, !macLabel.isEmpty {
            items.append(URLQueryItem(name: "n", value: macLabel))
        }
        components.queryItems = items
        return components.url
    }

    /// Parses a deep-link URL into a payload.
    /// - Throws: ``DecodingError`` describing the first missing or malformed
    ///   element. A version mismatch is reported distinctly so the UI can say
    ///   "this code is from an older build" rather than "invalid code".
    public static func decode(_ url: URL) throws -> PairingPayload {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.caseInsensitiveCompare("pair") == .orderedSame,
              let scheme = components.scheme
        else { throw DecodingError.notAPairingURL }

        let items = components.queryItems ?? []
        func values(_ name: String) -> [String] {
            items.filter { $0.name == name }.compactMap(\.value)
        }

        let declaredVersion = values("v").first.flatMap(Int.init)
        guard declaredVersion == version else {
            throw DecodingError.unsupportedVersion(declaredVersion)
        }
        guard let fingerprintHex = values("f").first,
              let fingerprint = DeviceFingerprint(hex: fingerprintHex)
        else { throw DecodingError.missingFingerprint }
        guard let ticket = values("t").first, !ticket.isEmpty else {
            throw DecodingError.missingTicket
        }
        let routes = values("r").filter { !$0.isEmpty }
        guard !routes.isEmpty else { throw DecodingError.missingRoutes }

        return PairingPayload(
            scheme: scheme,
            routes: routes,
            macFingerprint: fingerprint,
            enrollmentTicket: ticket,
            macLabel: values("n").first
        )
    }

    /// Whether a URL looks like a DeviceLink pairing link at all.
    public static func isPairingURL(_ url: URL) -> Bool {
        url.host?.caseInsensitiveCompare("pair") == .orderedSame
    }
}
