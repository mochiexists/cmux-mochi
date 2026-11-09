import Foundation
import Testing
@testable import CmuxTerminal

/// The deferred `cd` is typed into a live shell, so a directory name is
/// hostile input. These tests run the exact typed line through real shells
/// with `cd` stubbed out and prove the path arrives as one inert argument.
@Suite(.serialized)
struct TerminalWorkingDirectoryLaunchPlanInjectionTests {
    private static let home = "/Users/someone"

    /// Typeable hostile names: each must reach `cd` verbatim and run nothing.
    static let inertPaths = [
        "/Users/someone/x'; touch MARKER; '",
        "/Users/someone/$(touch MARKER)",
        "/Users/someone/`touch MARKER`",
        "/Users/someone/-rf; touch MARKER",
        "/Users/someone/a\"b;touch MARKER;\"",
        "/Users/someone/${HOME}*?[a]~ &| touch MARKER",
    ]

    /// Names the quoting cannot make inert: never typed.
    static let refusedPaths = [
        "/Users/someone/x\n touch MARKER",
        "/Users/someone/x\r touch MARKER",
        "/Users/someone/x\u{03}touch MARKER",
        "/Users/someone/x\u{15}touch MARKER",
        "/Users/someone/x\u{1B}[201~",
        "/Users/someone/x\u{7F}",
        "/Users/someone/x\u{9B}",
        "/Users/someone/x\u{0}y",
        "/Users/someone/x\\'; touch MARKER; '",
        "-rf",
        "relative/dir",
    ]

    @Test(arguments: inertPaths)
    func hostileButTypeablePathReachesCdAsOneArgument(path: String) throws {
        let input = try #require(stalledPlan(for: path, initialInput: nil).initialInput)

        #expect(input.hasPrefix("cd -- '"))
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
            let run = try runWithStubbedCd(shell: shell, line: input)
            #expect(run.arguments == ["--", path], "shell \(shell)")
            #expect(!run.markerCreated, "shell \(shell) executed part of the path")
        }
    }

    @Test(arguments: refusedPaths)
    func untypeablePathStaysInHomeAndTypesNothing(path: String) {
        let plan = stalledPlan(for: path, initialInput: "claude --resume abc\n")

        #expect(plan.workingDirectory == Self.home)
        #expect(plan.initialInput == nil)
        #expect(plan.deferredWorkingDirectory == path)
    }

    @Test
    func plannedInputStillChainsOnASafeCd() throws {
        let path = "/Users/someone/it's $(fine)"
        let input = try #require(
            stalledPlan(for: path, initialInput: "printf done\n").initialInput
        )

        let run = try runWithStubbedCd(shell: "/bin/zsh", line: input)

        #expect(run.arguments == ["--", path])
        #expect(run.output.hasSuffix("done"))
    }

    private func stalledPlan(for path: String, initialInput: String?) -> TerminalWorkingDirectoryLaunchPlan {
        TerminalWorkingDirectoryLaunchPlan.resolve(
            requestedWorkingDirectory: path,
            initialInput: initialInput,
            inputReachesShell: true,
            gate: TerminalWorkingDirectoryAccessGate(
                deadline: .milliseconds(1),
                homeDirectory: Self.home,
                probe: { _ in
                    Thread.sleep(forTimeInterval: 0.2)
                    return true
                }
            )
        )
    }

    /// Runs `line` in `shell` inside a scratch directory, with `cd` replaced
    /// by a function that prints each argument NUL-terminated.
    private func runWithStubbedCd(
        shell: String,
        line: String
    ) throws -> (arguments: [String], markerCreated: Bool, output: String) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cd-injection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.currentDirectoryURL = scratch
        process.arguments = ["-c", "cd() { for a in \"$@\"; do printf '%s\\0' \"$a\"; done; printf '\\n'; }\n" + line]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        let firstLine = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let arguments = firstLine.split(separator: "\0", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
        let markerCreated = FileManager.default.fileExists(atPath: scratch.appendingPathComponent("MARKER").path)
        return (arguments, markerCreated, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
