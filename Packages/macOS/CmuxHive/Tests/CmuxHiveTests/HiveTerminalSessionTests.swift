import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxHive

@MainActor
@Suite("Hive terminal session")
struct HiveTerminalSessionTests {
    @Test("forwards output with backpressure and routes input to the exact surface")
    func forwardsOutputAndInput() async {
        let shell = HiveTerminalShellStub()
        let session = HiveTerminalSession(surfaceID: "surface-a", shell: shell)
        let received = OutputRecorder()
        let token = UUID()
        await withCheckedContinuation { (outputDelivered: CheckedContinuation<Void, Never>) in
            session.attach { data in
                received.append(data)
                outputDelivered.resume()
            }
            shell.outputContinuation.yield(
                MobileTerminalOutputChunk(
                    data: Data("hello".utf8),
                    streamToken: token
                )
            )
        }
        session.send(Data("ls\n".utf8))

        #expect(received.data == Data("hello".utf8))
        #expect(shell.processed.count == 1)
        #expect(shell.processed.first?.surfaceID == "surface-a")
        #expect(shell.processed.first?.token == token)
        #expect(shell.inputs.count == 1)
        #expect(shell.inputs.first?.surfaceID == "surface-a")
        #expect(shell.inputs.first?.data == Data("ls\n".utf8))
        session.refreshVisibleScreen()
        #expect(shell.replayRequests == ["surface-a"])

        session.detach()
        #expect(shell.unmountedSurfaceID == "surface-a")
        #expect(shell.unmountedRegistrationToken == shell.registrationToken)
    }

    @Test("a naturally-ended output stream permits a new attachment")
    func reattachesAfterStreamEnd() async {
        let shell = HiveTerminalShellStub()
        let session = HiveTerminalSession(surfaceID: "surface-a", shell: shell)

        await withCheckedContinuation { (streamEnded: CheckedContinuation<Void, Never>) in
            session.attach(onOutput: { _ in }) {
                streamEnded.resume()
            }
            #expect(session.phase == .attached)
            shell.finishCurrentOutput()
        }
        #expect(session.phase == .idle)

        session.attach(onOutput: { _ in })
        #expect(session.phase == .attached)
        #expect(shell.registrationCount == 2)
        session.detach()
    }
}

@MainActor
private final class HiveTerminalShellStub: HiveTerminalShellServing {
    var registrationToken = UUID()
    var outputStream: AsyncStream<MobileTerminalOutputChunk>
    var outputContinuation: AsyncStream<MobileTerminalOutputChunk>.Continuation
    var registrationCount = 0
    var processed: [(surfaceID: String, token: UUID)] = []
    var inputs: [(surfaceID: String, data: Data)] = []
    var replayRequests: [String] = []
    var unmountedSurfaceID: String?
    var unmountedRegistrationToken: UUID?

    init() {
        (outputStream, outputContinuation) = AsyncStream.makeStream()
    }

    func terminalOutputRegistration(
        surfaceID: String
    ) -> MobileTerminalOutputRegistration {
        registrationCount += 1
        if registrationCount > 1 {
            registrationToken = UUID()
            (outputStream, outputContinuation) = AsyncStream.makeStream()
        }
        return MobileTerminalOutputRegistration(
            registrationToken: registrationToken,
            stream: outputStream
        )
    }

    func terminalOutputDidProcess(surfaceID: String, streamToken: UUID) {
        processed.append((surfaceID, streamToken))
    }

    func terminalOutputDidUnmount(surfaceID: String, registrationToken: UUID) {
        unmountedSurfaceID = surfaceID
        unmountedRegistrationToken = registrationToken
    }

    func sendTerminalRawInput(_ data: Data, surfaceID: String) {
        inputs.append((surfaceID, data))
    }

    func requestTerminalVisibleScreenReplay(surfaceID: String) {
        replayRequests.append(surfaceID)
    }

    func finishCurrentOutput() {
        outputContinuation.finish()
    }

    func prepareTerminalViewport(
        surfaceID: String,
        columns: Int,
        rows: Int
    ) -> MobileTerminalViewportPreparation? {
        nil
    }

    func updatePreparedTerminalViewport(
        _ preparation: MobileTerminalViewportPreparation
    ) async -> (
        columns: Int,
        rows: Int,
        renderEpoch: String?,
        renderRevisionFloor: UInt64?
    )? {
        nil
    }

    func updateTerminalViewport(
        surfaceID: String,
        columns: Int,
        rows: Int
    ) async -> (
        columns: Int,
        rows: Int,
        renderEpoch: String?,
        renderRevisionFloor: UInt64?
    )? {
        (columns, rows, nil, nil)
    }
}

private final class OutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()

    var data: Data { lock.withLock { stored } }

    func append(_ data: Data) {
        lock.withLock { stored.append(data) }
    }
}
