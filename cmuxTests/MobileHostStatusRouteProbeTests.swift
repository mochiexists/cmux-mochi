import CMUXMobileCore
import Foundation
import Network
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A loopback listener the probe can dial for real, so the production
/// ``MobileHostStatusRouteProbe`` is exercised over an actual socket rather than
/// only through the seam.
private final class ProbeTestListener: @unchecked Sendable {
    /// How an accepted connection behaves.
    enum Behavior {
        /// Decode the request frame and reply with a matching RPC response,
        /// exactly as `MobileHostRPCEnvelope.encodeResponse` would frame it.
        case answerStatus
        /// Accept and then say nothing, modelling a peer that completes the TCP
        /// handshake but never speaks the protocol.
        case staySilent
    }

    /// `NWListener` delivers on a queue; every mutation below happens on it, so
    /// the unchecked conformance is confined to that single-queue discipline.
    private let queue = DispatchQueue(label: "dev.cmux.tests.probe-listener")
    private let listener: NWListener
    private let behavior: Behavior
    private var accepted: [NWConnection] = []

    init(behavior: Behavior) throws {
        self.behavior = behavior
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening and resolves with the bound port.
    func start() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeGuard()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = self?.listener.port?.rawValue else { return }
                    resumed.resume(continuation, with: .success(Int(port)))
                case let .failed(error):
                    resumed.resume(continuation, with: .failure(error))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            for connection in accepted { connection.cancel() }
            accepted.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        accepted.append(connection)
        connection.start(queue: queue)
        guard case .answerStatus = behavior else { return }
        receiveAndAnswer(connection, buffer: Data())
    }

    private func receiveAndAnswer(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            guard error == nil, !isComplete, let data else { return }
            var pending = buffer + data
            guard let frames = try? MobileSyncFrameCodec.decodeFrames(from: &pending) else { return }
            for frame in frames {
                guard let object = try? JSONSerialization.jsonObject(with: frame),
                      let request = object as? [String: Any],
                      let id = request["id"] else {
                    continue
                }
                let response: [String: Any] = ["id": id, "ok": true, "result": [String: Any]()]
                guard let payload = try? JSONSerialization.data(withJSONObject: response),
                      let reply = try? MobileSyncFrameCodec.encodeFrame(payload) else {
                    continue
                }
                connection.send(content: reply, completion: .idempotent)
            }
            self.receiveAndAnswer(connection, buffer: pending)
        }
    }

    /// One-shot continuation guard: `stateUpdateHandler` can fire more than once
    /// and only the first transition may resume. A synchronous compare-and-set
    /// from a non-async callback — the sanctioned lock carve-out, not an actor.
    private final class ResumeGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false

        func resume(
            _ continuation: CheckedContinuation<Int, any Error>,
            with result: Result<Int, any Error>
        ) {
            lock.lock()
            let shouldResume = !didResume
            didResume = true
            lock.unlock()
            guard shouldResume else { return }
            continuation.resume(with: result)
        }
    }
}

@Suite struct MobileHostStatusRouteProbeTests {
    private func loopbackRoute(port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            priority: 0
        )
    }

    /// The happy path over a real socket: the probe frames a `mobile.host.status`
    /// request, the listener answers, and the route is verified.
    @Test func answeringListenerVerifiesTheRoute() async throws {
        let listener = try ProbeTestListener(behavior: .answerStatus)
        let port = try await listener.start()
        defer { listener.stop() }

        let result = await MobileHostStatusRouteProbe().probe(
            try loopbackRoute(port: port),
            timeoutNanoseconds: 5 * 1_000_000_000
        )

        guard case let .verified(latency) = result else {
            Issue.record("expected .verified, got \(result)")
            return
        }
        #expect(latency >= 0)
    }

    /// A peer that completes the handshake and then says nothing must not read
    /// as reachable — the reply deadline, not the connect deadline, decides.
    @Test func acceptingButSilentListenerTimesOut() async throws {
        let listener = try ProbeTestListener(behavior: .staySilent)
        let port = try await listener.start()
        defer { listener.stop() }

        let result = await MobileHostStatusRouteProbe().probe(
            try loopbackRoute(port: port),
            timeoutNanoseconds: 300_000_000
        )

        #expect(result == .unreachable(.timedOut))
        #expect(result.isVerified == false)
    }

    /// Nothing holding the port is a classified refusal, not a silent success.
    @Test func portWithNoListenerIsRefused() async throws {
        // Bind then release so the OS hands back a port it will immediately
        // refuse, rather than guessing an unused number.
        let listener = try ProbeTestListener(behavior: .staySilent)
        let port = try await listener.start()
        listener.stop()

        let result = await MobileHostStatusRouteProbe().probe(
            try loopbackRoute(port: port),
            timeoutNanoseconds: 2 * 1_000_000_000
        )

        #expect(result.isVerified == false)
        #expect(result.failureKind == .connectionRefused)
    }

    /// A non-host/port route carries nothing to dial, so it is reported as such
    /// instead of being quietly treated as fine.
    @Test func peerEndpointIsReportedUnsupported() async throws {
        let route = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                id: String(repeating: "e", count: 64),
                relayHint: nil,
                directAddrs: [],
                relayURL: nil
            ),
            priority: 5
        )

        let result = await MobileHostStatusRouteProbe().probe(
            route,
            timeoutNanoseconds: 1_000_000_000
        )

        #expect(result == .unreachable(.unsupportedRoute))
    }
}
