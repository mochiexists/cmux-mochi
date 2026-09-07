public import DeviceLinkKit
import Foundation

/// User-facing failures while importing a Mac's DeviceLink pairing link.
public enum HivePairingLinkError: Error, Equatable, Sendable {
    /// The value is not the current DeviceLink v3 pairing grammar.
    case invalidLink
}

/// Decodes only the DeviceLink v3 link emitted by a Mochi host.
///
/// Hive intentionally does not accept the older attach-ticket grammars: those
/// carried application credentials and would reintroduce the auth paths the
/// fork removed. The returned payload still contains a short-lived enrollment
/// capability, but all subsequent traffic is authenticated by mutual TLS.
public struct HivePairingLinkDecoder: Sendable {
    public init() {}

    /// Decode a pasted pairing URL without changing its advertised route order.
    public func decode(_ rawValue: String) throws -> PairingPayload {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw HivePairingLinkError.invalidLink
        }
        do {
            return try PairingPayloadCoder.decode(url)
        } catch {
            throw HivePairingLinkError.invalidLink
        }
    }
}
