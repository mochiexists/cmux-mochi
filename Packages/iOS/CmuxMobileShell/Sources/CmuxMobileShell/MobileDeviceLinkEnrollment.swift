public import DeviceLinkKit
public import Foundation
internal import CmuxMobileTransport
internal import Network

/// Why an enrollment attempt ended.
public enum MobileDeviceLinkEnrollmentError: Error, Equatable {
    /// The scanned payload was not a DeviceLink pairing code.
    case notADeviceLinkPayload
    /// No identity could be created or read for this Mac.
    case identityUnavailable
    /// The payload advertised no dialable route.
    case noRoutes
    /// Every advertised route failed to connect.
    case unreachable
    /// The Mac answered, but its key is not the one the QR pinned. Someone
    /// else is answering on that address — never retried automatically.
    case serverPinMismatch
    /// The Mac refused the enrollment (expired/spent code, quota, throttle).
    case refused(code: String, message: String)
    /// The Mac answered something this build cannot interpret.
    case malformedResponse
}

/// What a successful enrollment established.
public struct MobileDeviceLinkEnrollmentOutcome: Sendable, Equatable {
    /// Stable local identity for this pairing, keyed by the Mac's public key.
    public let pairingID: String
    /// The Mac's pinned fingerprint.
    public let macFingerprint: DeviceFingerprint
    /// The route that worked, so the caller can store it for reconnection.
    public let route: String
    /// Whether the Mac already knew this device (a retried enrollment).
    public let wasAlreadyEnrolled: Bool
}

/// Performs the phone's side of DeviceLink pairing.
///
/// The whole ceremony is: create a key for this Mac, dial it with that key
/// while pinning the Mac's key from the QR, and — inside that mutually
/// authenticated channel — ask to be enrolled. No secret is transmitted in
/// either direction; both sides prove possession of keys they already hold.
public struct MobileDeviceLinkEnroller: Sendable {
    private let client: MobileDeviceLinkClient
    private let deviceLabel: String
    private let connectTimeoutNanoseconds: UInt64

    public init(
        client: MobileDeviceLinkClient = .shared,
        deviceLabel: String,
        connectTimeoutNanoseconds: UInt64 = 10_000_000_000
    ) {
        self.client = client
        self.deviceLabel = deviceLabel
        self.connectTimeoutNanoseconds = connectTimeoutNanoseconds
    }

    /// A pairing's stable local identity.
    ///
    /// Keyed by the Mac's public key rather than a device id, because the key
    /// is what the phone actually authenticates. A Mac that reinstalls and
    /// mints a new key is a new pairing — correctly, since the old key can no
    /// longer be proven.
    public static func pairingID(for fingerprint: DeviceFingerprint) -> String {
        "devicelink:\(fingerprint.hex)"
    }

    /// Runs enrollment against a scanned payload.
    ///
    /// The identity and pin are written **before** the request goes out, so a
    /// response lost in flight costs nothing: redialing presents the same key,
    /// and a Mac that already committed it simply admits the device.
    public func enroll(payload: PairingPayload) async throws -> MobileDeviceLinkEnrollmentOutcome {
        guard !payload.routes.isEmpty else {
            throw MobileDeviceLinkEnrollmentError.noRoutes
        }
        let pairingID = Self.pairingID(for: payload.macFingerprint)

        do {
            _ = try client.prepareIdentity(
                forPairingID: pairingID,
                macFingerprint: payload.macFingerprint
            )
        } catch {
            throw MobileDeviceLinkEnrollmentError.identityUnavailable
        }
        guard let tlsOptions = client.tlsOptions(forPairingID: pairingID) else {
            throw MobileDeviceLinkEnrollmentError.identityUnavailable
        }

        var lastError = MobileDeviceLinkEnrollmentError.unreachable
        for route in payload.routes {
            guard let (host, port) = Self.splitHostPort(route) else { continue }
            do {
                let outcome = try await enrollOverRoute(
                    host: host,
                    port: port,
                    tlsOptions: tlsOptions,
                    ticket: payload.enrollmentTicket
                )
                return MobileDeviceLinkEnrollmentOutcome(
                    pairingID: pairingID,
                    macFingerprint: payload.macFingerprint,
                    route: route,
                    wasAlreadyEnrolled: outcome
                )
            } catch let error as MobileDeviceLinkEnrollmentError {
                // A refusal or a pin mismatch is the Mac's final answer; trying
                // the next address would only ask a different machine the same
                // question.
                switch error {
                case .refused, .serverPinMismatch:
                    throw error
                default:
                    lastError = error
                }
            } catch {
                lastError = .unreachable
            }
        }
        throw lastError
    }

    private func enrollOverRoute(
        host: String,
        port: Int,
        tlsOptions: NWProtocolTLS.Options,
        ticket: String
    ) async throws -> Bool {
        let transport = try CmxNetworkByteTransport(
            host: host,
            port: port,
            connectTimeoutNanoseconds: connectTimeoutNanoseconds,
            tlsOptions: tlsOptions
        )
        do {
            try await transport.connect()
        } catch {
            // A pin mismatch surfaces as a failed secure channel. It is not a
            // transient network problem, so it must not be retried.
            throw MobileDeviceLinkEnrollmentError.serverPinMismatch
        }
        defer { Task { await transport.close() } }

        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": "mobile.pairing.device.enroll",
            "params": ["ticket": ticket, "device_label": deviceLabel],
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        try await transport.send(Self.frame(requestData))

        let responseData = try await Self.readFrame(from: transport)
        guard let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw MobileDeviceLinkEnrollmentError.malformedResponse
        }
        if let error = object["error"] as? [String: Any] {
            throw MobileDeviceLinkEnrollmentError.refused(
                code: error["code"] as? String ?? "unknown",
                message: error["message"] as? String ?? "Pairing was refused."
            )
        }
        guard let result = object["result"] as? [String: Any],
              result["enrolled"] as? Bool == true
        else {
            throw MobileDeviceLinkEnrollmentError.malformedResponse
        }
        return result["already_enrolled"] as? Bool ?? false
    }

    /// Splits `host:port`, tolerating bracketed IPv6 literals.
    static func splitHostPort(_ route: String) -> (host: String, port: Int)? {
        guard let separator = route.lastIndex(of: ":") else { return nil }
        let host = String(route[route.startIndex ..< separator])
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard let port = Int(route[route.index(after: separator)...]),
              (1 ... 65535).contains(port),
              !host.isEmpty
        else { return nil }
        return (host, port)
    }

    /// Length-prefixed framing, matching the host's wire protocol.
    static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(payload)
        return framed
    }

    private static func readFrame(from transport: CmxNetworkByteTransport) async throws -> Data {
        var buffer = Data()
        while buffer.count < 4 {
            guard let chunk = try await transport.receive(), !chunk.isEmpty else {
                throw MobileDeviceLinkEnrollmentError.malformedResponse
            }
            buffer.append(chunk)
        }
        let length = buffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        buffer = buffer.dropFirst(4)
        while buffer.count < Int(length) {
            guard let chunk = try await transport.receive(), !chunk.isEmpty else {
                throw MobileDeviceLinkEnrollmentError.malformedResponse
            }
            buffer.append(chunk)
        }
        return buffer.prefix(Int(length))
    }
}
