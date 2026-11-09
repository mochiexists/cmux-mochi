import Foundation
import Testing
@testable import CmuxTerminal

@Suite
struct TerminalWorkingDirectoryAccessGateTests {
    private static let shortDeadline: Duration = .milliseconds(50)
    /// "Returned at once": half the 500 ms deadline used by that test, so a
    /// loaded CI host cannot flake while a second full wait still fails.
    private static let immediateBound: TimeInterval = 0.25
    private static let deadlineBound: TimeInterval = 2

    @Test
    func openableDirectoryIsAccessible() {
        let gate = TerminalWorkingDirectoryAccessGate(deadline: Self.shortDeadline, probe: { _ in true })

        #expect(gate.check("/Users/someone/Documents/project") == .accessible)
        #expect(!gate.isStalled)
    }

    @Test
    func failedOpenIsUnavailableNotTimedOut() {
        let gate = TerminalWorkingDirectoryAccessGate(deadline: Self.shortDeadline, probe: { _ in false })

        #expect(gate.check("/missing") == .unavailable)
        #expect(!gate.isStalled)
    }

    @Test
    func stuckOpenTimesOutWithinTheDeadline() {
        let probe = BlockingDirectoryProbe()
        let gate = TerminalWorkingDirectoryAccessGate(deadline: Self.shortDeadline, probe: probe.open)
        defer { probe.answer() }

        let started = Date()
        let outcome = gate.check("/Users/someone/Documents/project")

        #expect(outcome == .timedOut)
        #expect(Date().timeIntervalSince(started) < Self.deadlineBound)
        #expect(gate.isStalled)
    }

    @Test
    func laterChecksDuringAStallAnswerAtOnceWithoutAnotherProbe() {
        let probe = BlockingDirectoryProbe()
        let gate = TerminalWorkingDirectoryAccessGate(deadline: .milliseconds(500), probe: probe.open)
        defer { probe.answer() }
        #expect(gate.check("/Users/someone/Documents/a") == .timedOut)

        let started = Date()
        let second = gate.check("/Users/someone/Documents/b")

        #expect(second == .timedOut)
        #expect(Date().timeIntervalSince(started) < Self.immediateBound)
        #expect(probe.startCount == 1)
    }

    @Test
    func stallClearsWhenTheStuckOpenReturns() async throws {
        let probe = BlockingDirectoryProbe()
        let gate = TerminalWorkingDirectoryAccessGate(deadline: Self.shortDeadline, probe: probe.open)
        #expect(gate.check("/Users/someone/Documents/a") == .timedOut)

        probe.answer()
        try await waitUntil { !gate.isStalled }
        probe.answer()

        #expect(gate.check("/Users/someone/Documents/a") == .accessible)
        #expect(probe.startCount == 2)
    }

    @Test
    func liveProbeOpensOnlyDirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-wd-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)

        #expect(TerminalWorkingDirectoryAccessGate.opensDirectory(directory.path))
        #expect(!TerminalWorkingDirectoryAccessGate.opensDirectory(file.path))
        #expect(!TerminalWorkingDirectoryAccessGate.opensDirectory(directory.appendingPathComponent("missing").path))
    }

    /// Waits for the probe thread's completion to land; bounded so a
    /// regression fails instead of hanging the suite.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}
