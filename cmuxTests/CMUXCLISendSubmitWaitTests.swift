import Foundation
import XCTest

/// Validates that `cmux send` documents the conductor-driving flags
/// (--enter/--submit atomic submit, and --wait + tuning options). The CLI lives
/// in its own `cmux-cli` module that isn't `@testable`-importable, so — like the
/// other CLI tests — this drives the bundled binary instead of constructing
/// `CMUXCLI` directly. Behavior of the live send/--wait path is exercised
/// against a running app, not here.
final class CMUXCLISendSubmitWaitTests: XCTestCase {
    private struct CLIRun {
        let output: String
        let status: Int32
        let timedOut: Bool
    }

    func testSendHelpDocumentsSubmitFlags() throws {
        let cli = try BundledCLITestSupport.bundledCLIPath(for: Self.self)
        let result = runCLI(cli, ["send", "--help"], timeout: 15)
        XCTAssertFalse(result.timedOut, "send --help timed out:\n\(result.output)")
        for token in ["--enter", "--submit"] {
            XCTAssertTrue(
                result.output.contains(token),
                "`cmux send --help` should document \(token). Got:\n\(result.output)"
            )
        }
    }

    func testSendHelpExplainsSendOnlyTypes() throws {
        let cli = try BundledCLITestSupport.bundledCLIPath(for: Self.self)
        let result = runCLI(cli, ["send", "--help"], timeout: 15)
        XCTAssertFalse(result.timedOut, "send --help timed out:\n\(result.output)")
        // The submit-ownership lesson must stay in the help: send types, --enter submits.
        XCTAssertTrue(
            result.output.lowercased().contains("only types") || result.output.contains("only TYPES"),
            "send --help should state that send only types the text. Got:\n\(result.output)"
        )
    }

    private func runCLI(_ path: String, _ args: [String], timeout: TimeInterval) -> CLIRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return CLIRun(output: "failed to launch: \(error)", status: -1, timedOut: false)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            return CLIRun(output: "", status: -1, timedOut: true)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return CLIRun(
            output: String(data: data, encoding: .utf8) ?? "",
            status: process.terminationStatus,
            timedOut: false
        )
    }
}
