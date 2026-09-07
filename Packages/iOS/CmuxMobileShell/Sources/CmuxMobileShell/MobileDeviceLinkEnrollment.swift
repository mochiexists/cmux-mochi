public import DeviceLinkKit
public import Foundation
internal import CMUXMobileCore
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
    /// The Mac's own device id, read from the authenticated channel.
    ///
    /// Stored pairings are keyed by this, because every existing identity and
    /// build-compatibility check compares against it. Keying them by the
    /// DeviceLink pairing id instead made reconnect dial a Mac whose reported
    /// identity never matched, so the connection was refused after dialing.
    public let macDeviceID: String
    /// The Mac's app-instance tag, which distinguishes Stable/Nightly/dev.
    public let macInstanceTag: String?
    /// Display name reported by the Mac.
    public let macDisplayName: String?
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
    private let localNetworkConnectTimeoutNanoseconds: UInt64

    public init(
        client: MobileDeviceLinkClient = .shared,
        deviceLabel: String,
        connectTimeoutNanoseconds: UInt64 = 10_000_000_000,
        localNetworkConnectTimeoutNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.client = client
        self.deviceLabel = deviceLabel
        self.connectTimeoutNanoseconds = max(1, connectTimeoutNanoseconds)
        self.localNetworkConnectTimeoutNanoseconds = max(
            1,
            localNetworkConnectTimeoutNanoseconds
        )
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
            // Name the keychain error. `identityUnavailable` alone cannot tell
            // "this device cannot make a key" from "it made one and cannot read
            // it back", and those have opposite fixes.
            MobileDeviceLinkDiagnostics.log("enroll: identity preparation failed: \(error)")
            throw MobileDeviceLinkEnrollmentError.identityUnavailable
        }
        guard let tlsOptions = client.tlsOptions(forPairingID: pairingID) else {
            MobileDeviceLinkDiagnostics.log(
                "enroll: no TLS options after preparing identity for \(pairingID.prefix(24))"
            )
            throw MobileDeviceLinkEnrollmentError.identityUnavailable
        }

        var lastError = MobileDeviceLinkEnrollmentError.unreachable
        for route in Self.orderedRoutes(payload.routes) {
            guard let (host, port) = Self.splitHostPort(route) else { continue }
            // On a phone, loopback is the phone — never the Mac. The Mac
            // advertises it for the simulator, which shares the Mac's network
            // stack and can only reach it that way.
            if Self.isLoopbackHost(host), Self.isPhysicalDevice { continue }
            do {
                let outcome = try await enrollOverRoute(
                    host: host,
                    port: port,
                    tlsOptions: tlsOptions,
                    ticket: payload.enrollmentTicket,
                    connectTimeoutNanoseconds: Self.connectTimeoutNanoseconds(
                        for: host,
                        localNetwork: localNetworkConnectTimeoutNanoseconds,
                        other: connectTimeoutNanoseconds
                    )
                )
                return MobileDeviceLinkEnrollmentOutcome(
                    pairingID: pairingID,
                    macDeviceID: outcome.identity.deviceID,
                    macInstanceTag: outcome.identity.instanceTag,
                    macDisplayName: outcome.identity.displayName,
                    macFingerprint: payload.macFingerprint,
                    route: route,
                    wasAlreadyEnrolled: outcome.wasAlreadyEnrolled
                )
            } catch let error as MobileDeviceLinkEnrollmentError {
                // Name the per-route failure. Without this the loop reports only
                // the last route's verdict, so an enrollment the Mac completed
                // over loopback still surfaced as a flat "unreachable" — the two
                // sides disagreeing with no way to see where.
                MobileDeviceLinkDiagnostics.log("enroll route \(host):\(port) failed: \(error)")
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
                MobileDeviceLinkDiagnostics.log("enroll route \(host):\(port) failed: \(error)")
                lastError = .unreachable
            }
        }
        throw lastError
    }

    /// What the Mac reports about itself once the channel is authenticated.
    struct MacIdentity: Sendable {
        var deviceID: String
        var instanceTag: String?
        var displayName: String?
    }

    private struct RouteOutcome: Sendable {
        var wasAlreadyEnrolled: Bool
        var identity: MacIdentity
    }

    private func enrollOverRoute(
        host: String,
        port: Int,
        tlsOptions: NWProtocolTLS.Options,
        ticket: String,
        connectTimeoutNanoseconds: UInt64
    ) async throws -> RouteOutcome {
        let transport = try CmxNetworkByteTransport(
            host: host,
            port: port,
            connectTimeoutNanoseconds: connectTimeoutNanoseconds,
            tlsOptions: tlsOptions
        )
        do {
            try await transport.connect()
        } catch {
            // A failed connect can mean the address is unreachable, nothing is
            // listening, or the peer presented the wrong key — and they are not
            // distinguishable here. Treat it as "this route did not work" so the
            // remaining routes still get a turn; only an explicit refusal from
            // the Mac (below) ends the whole attempt.
            throw MobileDeviceLinkEnrollmentError.unreachable
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
        let wasAlreadyEnrolled = result["already_enrolled"] as? Bool ?? false

        // The connection keeps its enrollment-candidate authorization context
        // until it closes. Identity therefore travels in the successful
        // enrollment response rather than through a second, forbidden status
        // request. Persisting it is what lets reconnect recognise this Mac.
        let identity = try Self.enrollmentIdentity(from: result)
        return RouteOutcome(wasAlreadyEnrolled: wasAlreadyEnrolled, identity: identity)
    }

    static func connectTimeoutNanoseconds(
        for host: String,
        localNetwork: UInt64,
        other: UInt64
    ) -> UInt64 {
        CmxLocalNetworkHost().matches(host) ? localNetwork : other
    }

    /// Keep direct LAN first, then use the durable tailnet hostname before
    /// numeric Tailscale snapshots. On iOS the MagicDNS lookup activates and
    /// selects the VPN path more reliably than an unbound CGNAT connection;
    /// reconnect later uses the route-aware factory to bind that path exactly.
    static func orderedRoutes(_ routes: [String]) -> [String] {
        routes.enumerated().sorted { left, right in
            let leftPriority = enrollmentRoutePriority(left.element)
            let rightPriority = enrollmentRoutePriority(right.element)
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            return left.offset < right.offset
        }.map(\.element)
    }

    private static func enrollmentRoutePriority(_ route: String) -> Int {
        guard let (host, _) = splitHostPort(route) else { return 4 }
        if isLoopbackHost(host) { return 0 }
        if CmxLocalNetworkHost().matches(host) { return 1 }
        let normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedHost.hasSuffix(".ts.net") { return 2 }
        return 3
    }

    static func enrollmentIdentity(from result: [String: Any]) throws -> MacIdentity {
        guard let deviceID = result["mac_device_id"] as? String,
              !deviceID.isEmpty
        else {
            throw MobileDeviceLinkEnrollmentError.malformedResponse
        }
        // The host publishes these under `mac_`-prefixed keys. Reading the
        // wrong key yields a nil instance tag, and the build-compatibility
        // policy fails CLOSED on a missing tag — so the pairing is silently
        // discarded and the phone can never reconnect to its own Mac.
        return MacIdentity(
            deviceID: deviceID,
            instanceTag: result["mac_instance_tag"] as? String,
            displayName: result["mac_display_name"] as? String
        )
    }

    /// Whether a host refers to the local device.
    static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized == "127.0.0.1" || normalized == "::1" || normalized == "localhost"
    }

    /// Whether this build runs on real hardware.
    static var isPhysicalDevice: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
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
