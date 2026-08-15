import Foundation
import Network
import Security
import Testing

@testable import DeviceLinkKit

/// End-to-end TLS behavior over a real loopback listener.
///
/// These are the tests the design calls for: not "does the verify block get
/// called" but "does an unauthorized device actually fail to talk to us". They
/// exercise Network.framework for real, which is the only way to catch the
/// TLS-1.3 admission subtlety asserted below.
@Suite("TLS loopback", .serialized)
struct TLSLoopbackTests {
    // MARK: - test identities

    /// Builds a `SecIdentity` from generated material, without touching the
    /// app keychain (tests must not depend on entitlements).
    private static func makeSecIdentity(label: String) throws -> (SecIdentity, DeviceFingerprint) {
        let material = try DeviceIdentityMaterial.generate(commonName: label)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devicelink-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let keyURL = directory.appendingPathComponent("key.pem")
        let certURL = directory.appendingPathComponent("cert.pem")
        let p12URL = directory.appendingPathComponent("identity.p12")
        try material.pemPrivateKey.write(to: keyURL, atomically: true, encoding: .utf8)
        let certPEM = "-----BEGIN CERTIFICATE-----\n"
            + material.derEncodedCertificate.base64EncodedString(options: [.lineLength64Characters])
            + "\n-----END CERTIFICATE-----\n"
        try certPEM.write(to: certURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "pkcs12", "-export",
            "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1",
            "-inkey", keyURL.path, "-in", certURL.path, "-out", p12URL.path,
            "-passout", "pass:devicelink-test", "-name", label,
        ]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "openssl pkcs12 export failed")

        var imported: CFArray?
        let status = SecPKCS12Import(
            try Data(contentsOf: p12URL) as CFData,
            [kSecImportExportPassphrase as String: "devicelink-test"] as CFDictionary,
            &imported
        )
        try #require(status == errSecSuccess, "SecPKCS12Import failed: \(status)")
        let items = try #require(imported as? [[String: Any]])
        let identity = try #require(items.first?[kSecImportItemIdentity as String])
        return (identity as! SecIdentity, material.fingerprint)
    }

    // MARK: - harness

    /// A listener that records what it actually admitted — the server's own
    /// view, which is the only authoritative one.
    private final class Server: @unchecked Sendable {
        let listener: NWListener
        private(set) var port: NWEndpoint.Port = NWEndpoint.Port(rawValue: 1)!
        private let lock = NSLock()
        private var admittedCount = 0
        private var connections: [NWConnection] = []

        var didAdmit: Bool {
            lock.lock(); defer { lock.unlock() }
            return admittedCount > 0
        }

        init(identity: SecIdentity, authorized: Set<DeviceFingerprint>) throws {
            let options = DeviceLinkTLS.listenerOptions(identity: identity) { fingerprint in
                authorized.contains(fingerprint)
            }
            let parameters = NWParameters(tls: options)
            parameters.allowLocalEndpointReuse = true
            listener = try NWListener(using: parameters, on: .any)

            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.lock.lock(); self.connections.append(connection); self.lock.unlock()
                connection.stateUpdateHandler = { state in
                    guard case .ready = state else { return }
                    self.lock.lock(); self.admittedCount += 1; self.lock.unlock()
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, _ in
                        guard let data, !data.isEmpty else { return }
                        connection.send(content: data, completion: .contentProcessed { _ in })
                    }
                }
                connection.start(queue: .global())
            }
            listener.start(queue: .global())
            guard ready.wait(timeout: .now() + 10) == .success, let bound = listener.port else {
                throw TestFailure.listenerNeverReady
            }
            port = bound
        }

        func stop() {
            lock.lock(); connections.forEach { $0.cancel() }; lock.unlock()
            listener.cancel()
        }
    }

    private enum TestFailure: Error { case listenerNeverReady }

    /// What the *client* observed.
    private enum ClientOutcome: Equatable {
        /// A full request/response completed — the only honest proof of
        /// admission (see `readyIsNotAdmission`).
        case roundTripped(negotiatedALPN: String?)
        /// The socket opened but no data came back.
        case openedButUnusable
        /// The handshake failed outright.
        case refused
        case timedOut
    }

    private static func connect(
        to port: NWEndpoint.Port,
        options: NWProtocolTLS.Options?,
        timeout: TimeInterval = 8
    ) -> ClientOutcome {
        let parameters: NWParameters = options.map { NWParameters(tls: $0) } ?? NWParameters(tls: nil)
        let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
        let done = DispatchSemaphore(value: 0)
        let box = OutcomeBox()

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                var negotiated: String?
                if let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                    negotiated = DeviceLinkTLS.negotiatedApplicationProtocol(from: metadata)
                }
                connection.send(content: Data("ping".utf8), completion: .contentProcessed { error in
                    guard error == nil else { box.finish(.openedButUnusable, done); return }
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, receiveError in
                        if receiveError != nil || data == nil || data!.isEmpty {
                            box.finish(.openedButUnusable, done)
                        } else {
                            box.finish(.roundTripped(negotiatedALPN: negotiated), done)
                        }
                    }
                })
            case .failed, .cancelled, .waiting:
                box.finish(.refused, done)
            default:
                break
            }
        }
        connection.start(queue: .global())
        _ = done.wait(timeout: .now() + timeout)
        connection.cancel()
        return box.value
    }

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ClientOutcome = .timedOut
        private var settled = false

        var value: ClientOutcome {
            lock.lock(); defer { lock.unlock() }
            return stored
        }

        func finish(_ outcome: ClientOutcome, _ semaphore: DispatchSemaphore) {
            lock.lock()
            let shouldSignal = !settled
            if !settled { stored = outcome; settled = true }
            lock.unlock()
            if shouldSignal { semaphore.signal() }
        }
    }

    // MARK: - cases

    @Test("a paired device completes a round trip and negotiates the DeviceLink ALPN")
    func pairedDeviceConnects() throws {
        let (serverIdentity, serverFingerprint) = try Self.makeSecIdentity(label: "mac")
        let (clientIdentity, clientFingerprint) = try Self.makeSecIdentity(label: "phone")
        let server = try Server(identity: serverIdentity, authorized: [clientFingerprint])
        defer { server.stop() }

        let outcome = Self.connect(
            to: server.port,
            options: DeviceLinkTLS.connectionOptions(
                identity: clientIdentity,
                expectedServerFingerprint: serverFingerprint
            )
        )

        #expect(outcome == .roundTripped(negotiatedALPN: DeviceLinkTLS.applicationProtocol))
        #expect(server.didAdmit)
    }

    @Test("a wrong server pin is refused before any application data is sent")
    func impostorServerRefused() throws {
        let (serverIdentity, _) = try Self.makeSecIdentity(label: "impostor-mac")
        let (clientIdentity, clientFingerprint) = try Self.makeSecIdentity(label: "phone")
        let (_, unrelatedFingerprint) = try Self.makeSecIdentity(label: "the-real-mac")
        let server = try Server(identity: serverIdentity, authorized: [clientFingerprint])
        defer { server.stop() }

        let outcome = Self.connect(
            to: server.port,
            options: DeviceLinkTLS.connectionOptions(
                identity: clientIdentity,
                expectedServerFingerprint: unrelatedFingerprint
            )
        )

        #expect(outcome == .refused)
        #expect(server.didAdmit == false)
    }

    @Test("an unenrolled device is never admitted and no data flows")
    func unknownClientRefused() throws {
        let (serverIdentity, serverFingerprint) = try Self.makeSecIdentity(label: "mac")
        let (_, pairedFingerprint) = try Self.makeSecIdentity(label: "paired-phone")
        let (strangerIdentity, _) = try Self.makeSecIdentity(label: "stranger-phone")
        let server = try Server(identity: serverIdentity, authorized: [pairedFingerprint])
        defer { server.stop() }

        let outcome = Self.connect(
            to: server.port,
            options: DeviceLinkTLS.connectionOptions(
                identity: strangerIdentity,
                expectedServerFingerprint: serverFingerprint
            )
        )

        #expect(outcome != .roundTripped(negotiatedALPN: DeviceLinkTLS.applicationProtocol))
        #expect(server.didAdmit == false)
    }

    /// The finding that changed the design (Phase 0b spike).
    ///
    /// TLS 1.3 sends the client certificate *after* the server's Finished, so a
    /// rejected client can still see `.ready`. A client that reported
    /// "connected" at that point would be lying to the user about a connection
    /// the Mac already refused — hence the rule that only a completed round
    /// trip counts as admission.
    @Test("client readiness alone does not prove server admission")
    func readyIsNotAdmission() throws {
        let (serverIdentity, serverFingerprint) = try Self.makeSecIdentity(label: "mac")
        let (_, pairedFingerprint) = try Self.makeSecIdentity(label: "paired-phone")
        let (strangerIdentity, _) = try Self.makeSecIdentity(label: "stranger-phone")
        let server = try Server(identity: serverIdentity, authorized: [pairedFingerprint])
        defer { server.stop() }

        let outcome = Self.connect(
            to: server.port,
            options: DeviceLinkTLS.connectionOptions(
                identity: strangerIdentity,
                expectedServerFingerprint: serverFingerprint
            )
        )

        // Whatever the socket appeared to do, the server never admitted it and
        // the client never got a byte back.
        #expect(server.didAdmit == false)
        if case .roundTripped = outcome {
            Issue.record("an unauthorized client completed a round trip")
        }
    }

    @Test("a plaintext client cannot talk to the TLS listener")
    func plaintextRejected() throws {
        let (serverIdentity, _) = try Self.makeSecIdentity(label: "mac")
        let (_, pairedFingerprint) = try Self.makeSecIdentity(label: "paired-phone")
        let server = try Server(identity: serverIdentity, authorized: [pairedFingerprint])
        defer { server.stop() }

        let outcome = Self.connect(to: server.port, options: nil, timeout: 5)

        if case .roundTripped = outcome {
            Issue.record("plaintext client established a usable session")
        }
        #expect(server.didAdmit == false)
    }

    @Test("revoking a device stops the next connection attempt")
    func revokedDeviceCannotReconnect() throws {
        let (serverIdentity, serverFingerprint) = try Self.makeSecIdentity(label: "mac")
        let (clientIdentity, clientFingerprint) = try Self.makeSecIdentity(label: "phone")

        // Authorization is read live, exactly as the coordinator provides it.
        let authorized = AuthorizedSet([clientFingerprint])
        let options = DeviceLinkTLS.listenerOptions(identity: serverIdentity) { authorized.contains($0) }
        let parameters = NWParameters(tls: options)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        let admitted = AdmissionCounter()
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                admitted.increment()
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, _ in
                    guard let data, !data.isEmpty else { return }
                    connection.send(content: data, completion: .contentProcessed { _ in })
                }
            }
            connection.start(queue: .global())
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        try #require(ready.wait(timeout: .now() + 10) == .success)
        let port = try #require(listener.port)

        let before = Self.connect(
            to: port,
            options: DeviceLinkTLS.connectionOptions(identity: clientIdentity, expectedServerFingerprint: serverFingerprint)
        )
        #expect(before == .roundTripped(negotiatedALPN: DeviceLinkTLS.applicationProtocol))

        authorized.remove(clientFingerprint)

        // Resumption is disabled, so this handshake re-runs the verify block
        // rather than replaying a cached session.
        let after = Self.connect(
            to: port,
            options: DeviceLinkTLS.connectionOptions(identity: clientIdentity, expectedServerFingerprint: serverFingerprint)
        )
        if case .roundTripped = after {
            Issue.record("a revoked device reconnected")
        }
    }

    private final class AuthorizedSet: @unchecked Sendable {
        private var storage: Set<DeviceFingerprint>
        private let lock = NSLock()

        init(_ initial: Set<DeviceFingerprint>) { storage = initial }

        func contains(_ fingerprint: DeviceFingerprint) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return storage.contains(fingerprint)
        }

        func remove(_ fingerprint: DeviceFingerprint) {
            lock.lock(); storage.remove(fingerprint); lock.unlock()
        }
    }

    private final class AdmissionCounter: @unchecked Sendable {
        private var count = 0
        private let lock = NSLock()
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}
