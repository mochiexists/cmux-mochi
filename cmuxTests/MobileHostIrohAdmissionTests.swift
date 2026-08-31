import CMUXMobileCore
import CmuxAgentChat
import CmuxIrohTransport
import CmuxMobileRPC
import Foundation
@preconcurrency import Network
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
extension MobileHostAuthorizationTests {

    @Test func testBindingPublicationDoesNotWaitForPersistence() async {
        let queue = MobileHostIrohPersistenceQueue()
        let gate = MobileHostIrohPersistenceGate()
        var published = false

        queue.publishAndEnqueue(
            publish: { published = true },
            persist: { await gate.wait() }
        )
        await gate.waitUntilStarted()

        #expect(published)
        await queue.cancel()
        await gate.resume()
    }

    #if DEBUG
    @Test func testMacIrohVerificationModeUsesTheSharedDefaultsContract() throws {
        let suiteName = "MobileHostIrohAdmissionTests.transport-mode.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(MobileHostIrohRuntime.debugTransportVerificationMode(defaults: defaults) == .automatic)
        defaults.set(
            CmxIrohPathPreference.relayOnly.rawValue,
            forKey: CmxIrohPathPreference.defaultsKey
        )
        #expect(MobileHostIrohRuntime.debugTransportVerificationMode(defaults: defaults) == .relayOnly)
        defaults.set(
            CmxIrohTransportVerificationMode.directOnly.rawValue,
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        )
        #expect(MobileHostIrohRuntime.debugTransportVerificationMode(defaults: defaults) == .directOnly)
        defaults.removeObject(forKey: CmxIrohTransportVerificationMode.debugDefaultsKey)
        defaults.set(
            CmxIrohPathPreference.automatic.rawValue,
            forKey: CmxIrohPathPreference.defaultsKey
        )
        defaults.set(true, forKey: MobileHostIrohRuntime.debugRelayOnlyDefaultsKey)
        #expect(MobileHostIrohRuntime.debugTransportVerificationMode(defaults: defaults) == .relayOnly)
    }
    #endif

    @Test func admittedIrohRequestNeedsNoPerRequestBearer() async throws {
        let request = MobileHostRPCRequest(
            id: "workspace-list",
            method: "workspace.list",
            params: [:]
        )
        let admitted = await MobileHostService.connectionAuthorizationError(
            for: request,
            authorization: try irohAdmissionContext()
        )
        #expect(admitted == nil)
    }
}

@MainActor
@Suite(.serialized)
struct IrohDeviceLinkMacGateTests {

    @Test func privateNetworkRoutesPrioritizeNumericTailscaleAndNeverUseLoopback() throws {
        let snapshot = MobileRouteResolver().routes(
            port: 58_465,
            tailscaleHosts: [
                "127.0.0.1",
                "work-mac.tailnet.ts.net",
                "100.71.210.41",
            ]
        )
        let tailscaleRoutes = snapshot.routes.filter { $0.kind == .tailscale }

        #expect(tailscaleRoutes.count == 2)
        guard case let .hostPort(host, port) = tailscaleRoutes.first?.endpoint else {
            Issue.record("Expected a numeric Tailscale private-network route")
            return
        }
        #expect(host == "100.71.210.41")
        #expect(port == 58_465)
        #expect(tailscaleRoutes.allSatisfy { route in
            guard case let .hostPort(routeHost, _) = route.endpoint else { return false }
            return routeHost != "127.0.0.1"
        })
    }

    @Test func stableExplicitSettingStartsIrohAndDeviceLinkListener() throws {
        let suiteName = "IrohDeviceLinkMacGateTests.Current.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: MobileHostService.listeningEnabledDefaultsKey)

        let enabled = MobileHostService.isListeningEnabled(
            defaults: defaults,
            buildFlavor: .stable
        )
        let plan = MobileHostService.startupPlan(
            legacyListenerEnabled: enabled,
            legacyListenerRunning: false
        )

        #expect(plan.activatesIroh)
        #expect(plan.startsLegacyListener)
    }

    @Test func stableHistoricalSettingStartsIrohAndDeviceLinkListener() throws {
        let suiteName = "IrohDeviceLinkMacGateTests.Historical.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "cmuxMobilePairingHostEnabled")

        let enabled = MobileHostService.isListeningEnabled(
            defaults: defaults,
            buildFlavor: .stable
        )
        let plan = MobileHostService.startupPlan(
            legacyListenerEnabled: enabled,
            legacyListenerRunning: false
        )

        #expect(plan.activatesIroh)
        #expect(plan.startsLegacyListener)
    }
}

@MainActor
extension MobileHostAuthorizationTests {

    @Test func admittedTransportStatusUsesTransportIdentity() async throws {
        let admitted = await MobileHostService.connectionStatusResult(
            authorization: try irohAdmissionContext(),
            supportsArtifactLane: true
        )
        guard case let .ok(admittedPayload as [String: Any]) = admitted else {
            return #expect(Bool(false), "Admitted Iroh status must return an object")
        }
        #expect(admittedPayload["mac_device_id"] is String)
        let admittedCapabilities = try #require(admittedPayload["capabilities"] as? [String])
        #expect(admittedCapabilities.contains(MobileHostService.irohArtifactLaneCapability))

        let admittedWithoutHandler = await MobileHostService.connectionStatusResult(
            authorization: try irohAdmissionContext(),
            supportsArtifactLane: false
        )
        guard case let .ok(unownedPayload as [String: Any]) = admittedWithoutHandler else {
            return #expect(Bool(false), "Admitted Iroh status must return an object")
        }
        let unownedCapabilities = try #require(unownedPayload["capabilities"] as? [String])
        #expect(!unownedCapabilities.contains(MobileHostService.irohArtifactLaneCapability))

        let paired = await MobileHostService.connectionStatusResult(
            authorization: .pairedDevice(
                fingerprint: String(repeating: "b", count: 64),
                label: "iPhone 16"
            )
        )
        guard case let .ok(pairedPayload as [String: Any]) = paired else {
            return #expect(Bool(false), "Paired DeviceLink status must return an object")
        }
        #expect(pairedPayload["mac_device_id"] is String)
        let pairedCapabilities = try #require(pairedPayload["capabilities"] as? [String])
        #expect(!pairedCapabilities.contains(MobileHostService.irohArtifactLaneCapability))

        let candidate = await MobileHostService.connectionStatusResult(
            authorization: .enrollmentCandidate(fingerprint: String(repeating: "c", count: 64))
        )
        guard case let .ok(candidatePayload as [String: Any]) = candidate else {
            return #expect(Bool(false), "Enrollment candidate status must return an object")
        }
        #expect(candidatePayload["mac_device_id"] == nil)
    }

    @Test func testIrohTerminalLaneInputFramingSurvivesQUICChunkBoundaries() throws {
        var buffer = Data([0, 0])
        #expect(try MobileHostIrohApplicationLaneRouter.decodeTerminalInputFrames(from: &buffer).isEmpty)
        buffer.append(contentsOf: [0, 2, 0xc3])
        #expect(try MobileHostIrohApplicationLaneRouter.decodeTerminalInputFrames(from: &buffer).isEmpty)
        buffer.append(0xa9)
        #expect(
            try MobileHostIrohApplicationLaneRouter.decodeTerminalInputFrames(from: &buffer)
                == ["é"]
        )
        #expect(buffer.isEmpty)
    }

    @Test func testIrohDefaultArtifactLaneHandlerRejectsUntilConsumerRegisters() async throws {
        let stream = CmxIrohBidirectionalStream(
            receiveStream: ImmediateMobileHostIrohReceiveStream(),
            sendStream: BlockingMobileHostIrohSendStream()
        )
        let handler = MobileHostIrohRejectingArtifactLaneHandler()
        let resourceID = try CmxIrohResourceID("artifact:preview")
        let peer = CmxIrohAdmittedPeer(peer: CmxIrohGrantPeer(
            bindingID: "123e4567-e89b-42d3-a456-426614174001",
            deviceID: "123e4567-e89b-42d3-a456-426614174002",
            tag: "test",
            platform: .ios,
            endpointID: try CmxIrohPeerIdentity(
                endpointID: String(repeating: "a", count: 64)
            ),
            identityGeneration: 1
        ))
        #expect(
            await handler.handleArtifactLane(
                resourceID: resourceID,
                offset: 0,
                stream: stream,
                peer: peer
            ) == false
        )
    }

    @Test func testIrohArtifactDescriptorFailuresPreserveFileAndCapacitySemantics() {
        #expect(
            MobileHostIrohArtifactTransferRegistry.Error.invalidFile.issueFailure
                == .fileNotFound
        )
        #expect(
            MobileHostIrohArtifactTransferRegistry.Error.unavailable.issueFailure
                == .unavailable
        )
        #expect(
            MobileHostIrohArtifactTransferRegistry.Error.capacityExceeded.issueFailure
                == .unavailable
        )
    }

    @Test func testIrohArtifactCapabilityIsOpaquePeerBoundAndSeriallyResumable() async throws {
        let fixture = try MobileHostIrohArtifactFixture(contents: Data("abcdef".utf8))
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MobileHostIrohArtifactTestClock(now: now)
        let resourceID = try CmxIrohResourceID(
            "artifact:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        )
        let registry = MobileHostIrohArtifactTransferRegistry(
            timeToLive: 60,
            now: { clock.now },
            resourceID: { resourceID }
        )
        let peer = try irohPeer(endpointCharacter: "a")
        let otherPeer = try irohPeer(endpointCharacter: "b")

        let descriptor = try await registry.issue(
            canonicalPath: fixture.path,
            peer: peer
        )

        #expect(descriptor.resourceID == resourceID.value)
        #expect(descriptor.totalSize == 6)
        #expect(descriptor.expiresAt == now.addingTimeInterval(60))
        #expect(!descriptor.resourceID.contains(fixture.path))
        await #expect(throws: MobileHostIrohArtifactTransferRegistry.Error.peerMismatch) {
            try await registry.claim(
                resourceID: resourceID,
                offset: 2,
                peer: otherPeer
            )
        }

        let lease = try await registry.claim(
            resourceID: resourceID,
            offset: 2,
            peer: peer
        )
        #expect(lease.offset == 2)
        #expect(lease.totalSize == 6)
        await #expect(throws: MobileHostIrohArtifactTransferRegistry.Error.alreadyInUse) {
            try await registry.claim(
                resourceID: resourceID,
                offset: 3,
                peer: peer
            )
        }
        await registry.release(lease)

        let resumed = try await registry.claim(
            resourceID: resourceID,
            offset: 4,
            peer: peer
        )
        #expect(resumed.offset == 4)
        await registry.release(resumed)

        let unknownResource = try CmxIrohResourceID(
            "artifact:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        )
        await #expect(throws: MobileHostIrohArtifactTransferRegistry.Error.unknownResource) {
            try await registry.claim(
                resourceID: unknownResource,
                offset: 0,
                peer: peer
            )
        }

        let separateSessionRegistry = MobileHostIrohArtifactTransferRegistry(
            timeToLive: 60,
            now: { clock.now },
            resourceID: { resourceID }
        )
        await #expect(throws: MobileHostIrohArtifactTransferRegistry.Error.unknownResource) {
            try await separateSessionRegistry.claim(
                resourceID: resourceID,
                offset: 0,
                peer: peer
            )
        }

        clock.advance(by: 61)
        await #expect(throws: MobileHostIrohArtifactTransferRegistry.Error.expired) {
            try await registry.claim(
                resourceID: resourceID,
                offset: 0,
                peer: peer
            )
        }
    }

    @Test func testIrohArtifactHandlerStreamsAuthorizedOffsetAtLowPriority() async throws {
        let fixture = try MobileHostIrohArtifactFixture(contents: Data("abcdef".utf8))
        defer { fixture.remove() }
        let resourceID = try CmxIrohResourceID(
            "artifact:abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"
        )
        let registry = MobileHostIrohArtifactTransferRegistry(
            timeToLive: 60,
            now: Date.init,
            resourceID: { resourceID }
        )
        let peer = try irohPeer(endpointCharacter: "c")
        _ = try await registry.issue(canonicalPath: fixture.path, peer: peer)
        let send = RecordingMobileHostIrohArtifactSendStream()
        let receive = RecordingMobileHostIrohArtifactReceiveStream()
        let handler = MobileHostIrohArtifactLaneHandler(registry: registry)

        let didTakeOwnership = await handler.handleArtifactLane(
            resourceID: resourceID,
            offset: 2,
            stream: CmxIrohBidirectionalStream(
                receiveStream: receive,
                sendStream: send
            ),
            peer: peer
        )

        #expect(didTakeOwnership)
        #expect(await send.payload() == Data("cdef".utf8))
        #expect(await send.priorities() == [-10])
        #expect(await send.finishCount() == 1)
        #expect(await receive.stopCodes() == [0])
    }

    @Test func testIrohArtifactHandlerResetsIfFileChangesDuringTransfer() async throws {
        let fixture = try MobileHostIrohArtifactFixture(contents: Data("abcdef".utf8))
        defer { fixture.remove() }
        let resourceID = try CmxIrohResourceID(
            "artifact:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        )
        let registry = MobileHostIrohArtifactTransferRegistry(
            timeToLive: 60,
            now: Date.init,
            resourceID: { resourceID }
        )
        let peer = try irohPeer(endpointCharacter: "d")
        _ = try await registry.issue(canonicalPath: fixture.path, peer: peer)
        let send = MutatingMobileHostIrohArtifactSendStream(path: fixture.path)
        let receive = RecordingMobileHostIrohArtifactReceiveStream()

        let didTakeOwnership = await MobileHostIrohArtifactLaneHandler(
            registry: registry
        ).handleArtifactLane(
            resourceID: resourceID,
            offset: 0,
            stream: CmxIrohBidirectionalStream(
                receiveStream: receive,
                sendStream: send
            ),
            peer: peer
        )

        #expect(didTakeOwnership)
        #expect(await send.finishCount() == 0)
        #expect(await send.resetCodes() == [6])
        #expect(await receive.stopCodes() == [0, 6])
    }

    @Test func testIrohApplicationLaneQuotasReserveArtifactCapacity() {
        #expect(MobileHostIrohApplicationLaneRouter.maximumConcurrentTerminalLaneCount == 4)
        #expect(MobileHostIrohApplicationLaneRouter.maximumConcurrentArtifactLaneCount == 1)
        #expect(MobileHostIrohApplicationLaneRouter.maximumConcurrentLaneCount == 5)

        var quota = MobileHostIrohApplicationLaneQuota()
        let terminalIDs = (0..<5).map { _ in UUID() }
        for id in terminalIDs.prefix(4) {
            let didReserve = quota.reserve(id, laneClass: .terminal)
            #expect(didReserve)
        }
        let didReserveFifthTerminal = quota.reserve(terminalIDs[4], laneClass: .terminal)
        #expect(!didReserveFifthTerminal)
        let artifactID = UUID()
        let didReserveArtifact = quota.reserve(artifactID, laneClass: .artifact)
        #expect(didReserveArtifact)
        let didReserveSecondArtifact = quota.reserve(UUID(), laneClass: .artifact)
        #expect(!didReserveSecondArtifact)
        #expect(quota.terminalCount == 4)
        #expect(quota.artifactCount == 1)

        quota.release(terminalIDs[0])
        let didReuseTerminalCredit = quota.reserve(terminalIDs[4], laneClass: .terminal)
        #expect(didReuseTerminalCredit)
        quota.release(artifactID)
        let didReuseArtifactCredit = quota.reserve(UUID(), laneClass: .artifact)
        #expect(didReuseArtifactCredit)
    }

    private func irohPeer(
        endpointCharacter: Character,
        generation: Int = 1
    ) throws -> CmxIrohAdmittedPeer {
        CmxIrohAdmittedPeer(peer: CmxIrohGrantPeer(
            bindingID: "123e4567-e89b-42d3-a456-426614174001",
            deviceID: "123e4567-e89b-42d3-a456-426614174002",
            tag: "test",
            platform: .ios,
            endpointID: try CmxIrohPeerIdentity(
                endpointID: String(repeating: String(endpointCharacter), count: 64)
            ),
            identityGeneration: generation
        ))
    }

    func irohAdmissionContext() throws -> MobileHostConnectionAuthorizationContext {
        let endpointID = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        let peer = CmxIrohGrantPeer(
            bindingID: "123e4567-e89b-42d3-a456-426614174001",
            deviceID: "123e4567-e89b-42d3-a456-426614174002",
            tag: "ios-test",
            platform: .ios,
            endpointID: endpointID,
            identityGeneration: 1
        )
        return .irohAdmission(CmxIrohAdmittedPeer(peer: peer))
    }
}

private struct MobileHostIrohArtifactFixture {
    let directory: URL
    let path: String

    init(contents: Data) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-iroh-artifact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent("private-preview.bin")
        try contents.write(to: file, options: .atomic)
        self.directory = directory
        self.path = file.path
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class MobileHostIrohArtifactTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(now: Date) {
        value = now
    }

    var now: Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            value = value.addingTimeInterval(interval)
        }
    }
}

private actor RecordingMobileHostIrohArtifactSendStream: CmxIrohSendStream {
    private var chunks: [Data] = []
    private var observedPriorities: [Int32] = []
    private var observedFinishCount = 0

    func send(_ data: Data) {
        chunks.append(data)
    }

    func finish() {
        observedFinishCount += 1
    }

    func reset(errorCode _: UInt64) {}

    func setPriority(_ priority: Int32) {
        observedPriorities.append(priority)
    }

    func payload() -> Data {
        chunks.reduce(into: Data()) { $0.append($1) }
    }

    func priorities() -> [Int32] { observedPriorities }
    func finishCount() -> Int { observedFinishCount }
}

private actor RecordingMobileHostIrohArtifactReceiveStream: CmxIrohReceiveStream {
    private var observedStopCodes: [UInt64] = []

    func receive(maximumByteCount _: Int) -> Data? { nil }

    func stop(errorCode: UInt64) {
        observedStopCodes.append(errorCode)
    }

    func stopCodes() -> [UInt64] { observedStopCodes }
}

private actor MutatingMobileHostIrohArtifactSendStream: CmxIrohSendStream {
    private let path: String
    private var didMutate = false
    private var observedFinishCount = 0
    private var observedResetCodes: [UInt64] = []

    init(path: String) {
        self.path = path
    }

    func send(_: Data) throws {
        guard !didMutate else { return }
        didMutate = true
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("changed-size".utf8))
    }

    func finish() {
        observedFinishCount += 1
    }

    func reset(errorCode: UInt64) {
        observedResetCodes.append(errorCode)
    }

    func setPriority(_: Int32) {}

    func finishCount() -> Int { observedFinishCount }
    func resetCodes() -> [UInt64] { observedResetCodes }
}

private actor MobileHostIrohPersistenceGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
