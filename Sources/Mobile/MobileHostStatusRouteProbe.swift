import CMUXMobileCore
import CmuxMobileTransport
import Foundation

/// The production ``MobileHostRouteProbing``: opens a real TCP connection to the
/// advertised host/port and asks the listener for `mobile.host.status`, the one
/// unauthenticated verb (see `MobileHostService.requiresAuthorization(method:)`).
///
/// Reaching a protocol reply — not merely a completed TCP handshake — is what
/// makes the claim worth showing: an answered status frame proves *cmux's*
/// pairing listener is on that address, so a foreign process that happened to
/// grab the port reads as unreachable rather than as a healthy route.
///
/// The probe carries no credential of any kind. It therefore dials
/// ``CmxNetworkByteTransport`` by host/port rather than through
/// `CmxNetworkByteTransportFactory`, whose Tailscale gate exists to keep an
/// *account bearer* off a tunnel Network.framework cannot attribute (the same
/// reasoning already recorded on `CmxTransportAuthorizationMode.attachTicket`).
/// With no bearer and no ticket on the wire there is nothing for a spoofed
/// tunnel to capture, and the reply is the public identity-free payload.
struct MobileHostStatusRouteProbe: MobileHostRouteProbing {
    /// Why a connected peer still failed to answer the status request. Kept
    /// private to the probe; each case classifies itself so the caller only ever
    /// sees the shared ``DiagnosticFailureKind`` vocabulary.
    private enum ReplyFailure: DiagnosticFailureProviding {
        /// The peer closed the connection before answering.
        case closedBeforeReply
        /// The peer streamed more than a status reply can plausibly be.
        case replyTooLarge
        /// The bytes on the wire were not valid mobile-sync framing.
        case malformedFraming

        var diagnosticFailureKind: DiagnosticFailureKind {
            switch self {
            case .closedBeforeReply:
                .connectionClosed
            case .replyTooLarge, .malformedFraming:
                .protocolViolation
            }
        }
    }

    /// Guard against a peer that accepts the connection and then streams
    /// garbage: a status reply is a few kilobytes, so anything past this is not
    /// the reply we asked for.
    private static let maximumReplyByteCount = 512 * 1024

    func probe(
        _ route: CmxAttachRoute,
        timeoutNanoseconds: UInt64
    ) async -> CmxRouteReachability {
        guard case let .hostPort(host, port) = route.endpoint else {
            return .unreachable(.unsupportedRoute)
        }
        let deadline = max(1, timeoutNanoseconds)

        return await withTaskGroup(of: CmxRouteReachability?.self) { group in
            group.addTask {
                await Self.dial(host: host, port: port, timeoutNanoseconds: deadline)
            }
            group.addTask {
                // Bounded, cancellable deadline covering connect *and* reply:
                // the transport's own timeout only spans connect, so a peer that
                // accepts and then goes silent must still resolve quickly.
                // Cancelled by `cancelAll()` as soon as the dial answers.
                do {
                    try await ContinuousClock().sleep(
                        for: .nanoseconds(Int64(clamping: deadline))
                    )
                } catch {
                    return nil
                }
                return .unreachable(.timedOut)
            }
            while let outcome = await group.next() {
                guard let outcome else { continue }
                group.cancelAll()
                return outcome
            }
            return .unreachable(.unknown)
        }
    }

    /// Connect, send one `mobile.host.status` request frame, and wait for the
    /// matching reply. Folds every failure into the shared diagnostic
    /// vocabulary; `CmxNetworkByteTransportError` already conforms to
    /// ``DiagnosticFailureProviding``, so transport errors classify themselves.
    private static func dial(
        host: String,
        port: Int,
        timeoutNanoseconds: UInt64
    ) async -> CmxRouteReachability {
        let transport: CmxNetworkByteTransport
        do {
            transport = try CmxNetworkByteTransport(
                host: host,
                port: port,
                connectTimeoutNanoseconds: timeoutNanoseconds
            )
        } catch {
            return .unreachable(DiagnosticFailureKind.classify(error))
        }

        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await transport.connect()
            let requestID = UUID().uuidString
            let frame = try MobileSyncFrameCodec.encodeFrame(statusRequest(id: requestID))
            try await transport.send(frame)
            try await awaitStatusReply(from: transport, requestID: requestID)
            let elapsed = clock.now - start
            await transport.close()
            return .verified(latencyMilliseconds: elapsed.mobileHostWholeMilliseconds)
        } catch {
            await transport.close()
            if error is CancellationError {
                return .unreachable(.cancelled)
            }
            return .unreachable(DiagnosticFailureKind.classify(error))
        }
    }

    /// The unauthenticated status request envelope, matching
    /// `MobileHostRPCEnvelope.decodeRequest(_:)`.
    private static func statusRequest(id: String) -> Data {
        // A fixed-shape, string-keyed object, so `JSONSerialization` cannot fail
        // on it; the empty fallback is unreachable rather than a swallowed error.
        let envelope: [String: Any] = [
            "id": id,
            "method": "mobile.host.status",
            "params": [String: Any](),
        ]
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
    }

    /// Reads frames until one is a well-formed response to `requestID`.
    ///
    /// A response frame counts whether it reports `ok` or an error: either way
    /// the Mac's own RPC layer answered on that address, which is exactly what
    /// the route claim needs. Frames carrying another id are ignored so an
    /// unrelated server-pushed event cannot end the wait early.
    private static func awaitStatusReply(
        from transport: CmxNetworkByteTransport,
        requestID: String
    ) async throws {
        var buffer = Data()
        while true {
            guard let chunk = try await transport.receive() else {
                throw ReplyFailure.closedBeforeReply
            }
            buffer.append(chunk)
            guard buffer.count <= maximumReplyByteCount else {
                throw ReplyFailure.replyTooLarge
            }
            let frames: [Data]
            do {
                frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
            } catch {
                throw ReplyFailure.malformedFraming
            }
            for frame in frames where isResponse(frame, to: requestID) {
                return
            }
        }
    }

    /// Whether one decoded frame is the RPC response envelope for `requestID`.
    private static func isResponse(_ frame: Data, to requestID: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: frame),
              let payload = object as? [String: Any],
              payload["id"] as? String == requestID else {
            return false
        }
        return payload["ok"] != nil
    }
}

private extension Duration {
    /// This duration as whole milliseconds, rounded down, clamped at 0.
    var mobileHostWholeMilliseconds: Int {
        let parts = components
        let fromSeconds = parts.seconds * 1_000
        // attoseconds (1e-18 s) -> milliseconds (1e-3 s): divide by 1e15.
        let fromAttoseconds = parts.attoseconds / 1_000_000_000_000_000
        return max(0, Int(fromSeconds + fromAttoseconds))
    }
}
