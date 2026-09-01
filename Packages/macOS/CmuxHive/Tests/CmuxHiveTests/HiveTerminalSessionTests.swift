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
        session.attach { data in
            received.append(data)
        }

        let token = UUID()
        shell.outputContinuation.yield(
            MobileTerminalOutputChunk(
                data: Data("hello".utf8),
                streamToken: token
            )
        )
        await Task.yield()
        await Task.yield()
        session.send(Data("ls\n".utf8))

        #expect(received.data == Data("hello".utf8))
        #expect(shell.processed.count == 1)
        #expect(shell.processed.first?.surfaceID == "surface-a")
        #expect(shell.processed.first?.token == token)
        #expect(shell.inputs.count == 1)
        #expect(shell.inputs.first?.surfaceID == "surface-a")
        #expect(shell.inputs.first?.data == Data("ls\n".utf8))

        session.detach()
        #expect(shell.unmountedSurfaceID == "surface-a")
        #expect(shell.unmountedRegistrationToken == shell.registrationToken)
    }
}

@MainActor
private final class HiveTerminalShellStub: HiveTerminalShellServing {
    let registrationToken = UUID()
    let outputStream: AsyncStream<MobileTerminalOutputChunk>
    let outputContinuation: AsyncStream<MobileTerminalOutputChunk>.Continuation
    var processed: [(surfaceID: String, token: UUID)] = []
    var inputs: [(surfaceID: String, data: Data)] = []
    var unmountedSurfaceID: String?
    var unmountedRegistrationToken: UUID?

    init() {
        (outputStream, outputContinuation) = AsyncStream.makeStream()
    }

    func terminalOutputRegistration(
        surfaceID: String
    ) -> MobileTerminalOutputRegistration {
        MobileTerminalOutputRegistration(
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
