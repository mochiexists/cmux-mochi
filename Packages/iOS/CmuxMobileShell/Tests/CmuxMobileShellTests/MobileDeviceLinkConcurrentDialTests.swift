import DeviceLinkKit
import Foundation
@preconcurrency import Network
import Testing

@testable import CmuxMobileShell

@Suite("Concurrent DeviceLink credential selection", .serialized)
struct MobileDeviceLinkConcurrentDialTests {
    private static let concurrentDialIterations = 10

    @Test("simultaneous Mac dials use each request's exact identity and pin")
    func simultaneousMacDialsUseExactCredentials() async throws {
        let credentialStore = InMemoryMobileDeviceLinkCredentialStore()
        let defaultsSuite = "mobile-device-link-concurrent-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let client = MobileDeviceLinkClient(
            identityStore: credentialStore,
            pinStore: credentialStore,
            pairingIndexDefaults: defaults
        )
        let macA = "AAAA0000-0000-0000-0000-000000000021"
        let macB = "BBBB0000-0000-0000-0000-000000000022"
        let tagA = "office"
        let tagB = "lab"

        let serverA = try ConcurrentDeviceLinkServer(label: "mac-a")
        let serverB = try ConcurrentDeviceLinkServer(label: "mac-b")
        defer {
            serverA.stop()
            serverB.stop()
        }

        let pairingA = MobileDeviceLinkEnroller.pairingID(for: serverA.fingerprint)
        let pairingB = MobileDeviceLinkEnroller.pairingID(for: serverB.fingerprint)
        defer {
            client.forget(pairingID: pairingA)
            client.forget(pairingID: pairingB)
        }

        let phoneA = try client.prepareIdentity(
            forPairingID: pairingA,
            macFingerprint: serverA.fingerprint
        )
        let phoneB = try client.prepareIdentity(
            forPairingID: pairingB,
            macFingerprint: serverB.fingerprint
        )
        client.rememberPairing(
            macDeviceID: macA,
            instanceTag: tagA,
            pairingID: pairingA
        )
        client.rememberPairing(
            macDeviceID: macB,
            instanceTag: tagB,
            pairingID: pairingB
        )
        serverA.authorize(phoneA.fingerprint)
        serverB.authorize(phoneB.fingerprint)

        // The request-scoped API is the primary race protection: there is no
        // shared mutable "current target" for one dial to overwrite. Repeating
        // live simultaneous handshakes also guards against reintroducing one.
        for _ in 0 ..< Self.concurrentDialIterations {
            let gate = ConcurrentDialGate(participantCount: 2)
            async let outcomeA = Self.dial(
                client: client,
                macDeviceID: macA,
                instanceTag: tagA,
                server: serverA,
                gate: gate
            )
            async let outcomeB = Self.dial(
                client: client,
                macDeviceID: macB,
                instanceTag: tagB,
                server: serverB,
                gate: gate
            )

            let outcomes = await (outcomeA, outcomeB)
            #expect(
                outcomes.0 == .roundTripped(
                    negotiatedALPN: DeviceLinkTLS.applicationProtocol
                )
            )
            #expect(
                outcomes.1 == .roundTripped(
                    negotiatedALPN: DeviceLinkTLS.applicationProtocol
                )
            )
        }
        #expect(serverA.admittedFingerprints == [phoneA.fingerprint])
        #expect(serverB.admittedFingerprints == [phoneB.fingerprint])

        #expect(client.pairingTLSOptions(forMacDeviceID: macA, instanceTag: tagB) == nil)
        let wrongIdentityOutcome = await Self.dial(
            client: client,
            macDeviceID: macB,
            instanceTag: tagB,
            server: serverA,
            gate: nil,
            timeout: 2
        )
        #expect(
            wrongIdentityOutcome != .roundTripped(
                negotiatedALPN: DeviceLinkTLS.applicationProtocol
            )
        )
        #expect(serverA.admittedFingerprints == [phoneA.fingerprint])
    }

    private static func dial(
        client: MobileDeviceLinkClient,
        macDeviceID: String,
        instanceTag: String,
        server: ConcurrentDeviceLinkServer,
        gate: ConcurrentDialGate?,
        timeout: TimeInterval = 8
    ) async -> ConcurrentDeviceLinkClientOutcome {
        if let gate {
            await gate.arriveAndWait()
        }
        guard let options = client.pairingTLSOptions(
            forMacDeviceID: macDeviceID,
            instanceTag: instanceTag
        ) else {
            return .credentialMissing
        }
        return await ConcurrentDeviceLinkClient.connect(
            to: server.port,
            options: options,
            timeout: timeout
        )
    }
}

private actor ConcurrentDialGate {
    private let participantCount: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func arriveAndWait() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            guard waiters.count == participantCount else { return }
            let ready = waiters
            waiters.removeAll()
            for waiter in ready {
                waiter.resume()
            }
        }
    }
}

private final class InMemoryMobileDeviceLinkCredentialStore:
    MobileDeviceIdentityStoring,
    MobileServerPinStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var identities: [String: DeviceIdentityMaterial] = [:]
    private var storedPins: [String: DeviceFingerprint] = [:]

    func identity(forPairingID pairingID: String) throws -> DeviceIdentityMaterial? {
        lock.lock()
        defer { lock.unlock() }
        return identities[pairingID]
    }

    func save(_ material: DeviceIdentityMaterial, forPairingID pairingID: String) throws {
        lock.lock()
        identities[pairingID] = material
        lock.unlock()
    }

    func remove(pairingID: String) throws {
        lock.lock()
        identities[pairingID] = nil
        lock.unlock()
    }

    func pins() throws -> [String: DeviceFingerprint] {
        lock.lock()
        defer { lock.unlock() }
        return storedPins
    }

    func setPin(_ fingerprint: DeviceFingerprint, forPairingID pairingID: String) throws {
        lock.lock()
        storedPins[pairingID] = fingerprint
        lock.unlock()
    }

    func removePin(forPairingID pairingID: String) throws {
        lock.lock()
        storedPins[pairingID] = nil
        lock.unlock()
    }
}

private final class ConcurrentDeviceLinkServer: @unchecked Sendable {
    let fingerprint: DeviceFingerprint
    private(set) var port = NWEndpoint.Port(rawValue: 1)!

    private let listener: NWListener
    private let trust: ConcurrentAuthorizedFingerprints
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    var admittedFingerprints: Set<DeviceFingerprint> {
        trust.admittedFingerprints
    }

    init(label: String) throws {
        let material = try DeviceIdentityMaterial.generate(commonName: label)
        let identity = try SecIdentityFactory.makeIdentity(from: material)
        let trust = ConcurrentAuthorizedFingerprints()
        fingerprint = material.fingerprint
        self.trust = trust

        let options = DeviceLinkTLS.listenerOptions(identity: identity) { candidate in
            trust.authorize(candidate)
        }
        listener = try NWListener(using: NWParameters(tls: options), on: .any)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.lock()
            self.connections.append(connection)
            self.lock.unlock()
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64) {
                    data,
                        _,
                        _,
                        _ in
                    guard let data, !data.isEmpty else { return }
                    connection.send(content: data, completion: .contentProcessed { _ in })
                }
            }
            connection.start(queue: .global())
        }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 10) == .success,
              let port = listener.port
        else {
            listener.cancel()
            throw ConcurrentDeviceLinkTestError.listenerNeverReady
        }
        self.port = port
    }

    func authorize(_ fingerprint: DeviceFingerprint) {
        trust.insert(fingerprint)
    }

    func stop() {
        lock.lock()
        let activeConnections = connections
        connections.removeAll()
        lock.unlock()
        for connection in activeConnections {
            connection.cancel()
        }
        listener.cancel()
    }
}

private final class ConcurrentAuthorizedFingerprints: @unchecked Sendable {
    private let lock = NSLock()
    private var authorized: Set<DeviceFingerprint> = []
    private var admitted: Set<DeviceFingerprint> = []

    var admittedFingerprints: Set<DeviceFingerprint> {
        lock.lock()
        defer { lock.unlock() }
        return admitted
    }

    func insert(_ fingerprint: DeviceFingerprint) {
        lock.lock()
        authorized.insert(fingerprint)
        lock.unlock()
    }

    func authorize(_ fingerprint: DeviceFingerprint) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let isAuthorized = authorized.contains(fingerprint)
        if isAuthorized {
            admitted.insert(fingerprint)
        }
        return isAuthorized
    }
}

private enum ConcurrentDeviceLinkClientOutcome: Equatable {
    case roundTripped(negotiatedALPN: String?)
    case credentialMissing
    case refused
    case timedOut
}

private enum ConcurrentDeviceLinkClient {
    static func connect(
        to port: NWEndpoint.Port,
        options: NWProtocolTLS.Options,
        timeout: TimeInterval = 8
    ) async -> ConcurrentDeviceLinkClientOutcome {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: "127.0.0.1",
                port: port,
                using: NWParameters(tls: options)
            )
            let result = ConcurrentDeviceLinkResult(
                connection: connection,
                continuation: continuation
            )
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data("ping".utf8), completion: .contentProcessed { error in
                        guard error == nil else {
                            result.finish(.refused)
                            return
                        }
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 64) {
                            data,
                                _,
                                _,
                                receiveError in
                            guard receiveError == nil, data == Data("ping".utf8) else {
                                result.finish(.refused)
                                return
                            }
                            let metadata = connection.metadata(definition: NWProtocolTLS.definition)
                                as? NWProtocolTLS.Metadata
                            let negotiatedALPN = metadata.flatMap(
                                DeviceLinkTLS.negotiatedApplicationProtocol(from:)
                            )
                            result.finish(.roundTripped(negotiatedALPN: negotiatedALPN))
                        }
                    })
                case .failed, .cancelled:
                    result.finish(.refused)
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                result.finish(.timedOut)
            }
        }
    }
}

private final class ConcurrentDeviceLinkResult: @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: CheckedContinuation<ConcurrentDeviceLinkClientOutcome, Never>
    private let lock = NSLock()
    private var finished = false

    init(
        connection: NWConnection,
        continuation: CheckedContinuation<ConcurrentDeviceLinkClientOutcome, Never>
    ) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ outcome: ConcurrentDeviceLinkClientOutcome) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        connection.cancel()
        continuation.resume(returning: outcome)
    }
}

private enum ConcurrentDeviceLinkTestError: Error {
    case listenerNeverReady
}
