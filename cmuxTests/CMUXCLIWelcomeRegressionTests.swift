import Foundation
import Darwin
import Testing

@Suite(.serialized) struct CMUXCLIWelcomeRegressionTests {
    @Test func commandHelpAliasDoesNotConnectToSocket() throws {
        let cliPath = try bundledCLIPath()
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_ENABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = "127.0.0.1:58248"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ping", "help"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.stdout.contains("Usage: cmux ping"))
        #expect(!result.stdout.contains("Socket not found"))
        #expect(!result.stdout.contains("Missing relay auth metadata"))
    }

    @Test func welcomeHighlightsCurrentMochiFeatures() throws {
        let cliPath = try bundledCLIPath()
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["welcome"],
            environment: ["CMUX_CLI_SENTRY_DISABLED": "1"],
            timeout: 5
        )

        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.stdout.contains("Reopen last closed tab/workspace"))
        #expect(result.stdout.contains("Artifact panes"))
        #expect(result.stdout.contains("Resource Monitor"))
        #expect(result.stdout.contains("Conductor — drive visible Codex and Claude worker panes"))
        #expect(result.stdout.contains("surface-attributed lifecycle events"))
        #expect(result.stdout.contains("send guard for live non-agent jobs"))
        #expect(result.stdout.contains("Copy File"))
        #expect(result.stdout.contains("code tabs"))
        #expect(result.stdout.contains("Cmd+Shift+T restores closed tabs/workspaces"))
        #expect(result.stdout.contains("Sidebar stability"))
        #expect(result.stdout.contains("Privacy Frost — blur sensitive workspaces or groups"))
        #expect(result.stdout.contains("Passkeys/WebAuthn are temporarily disabled"))
        #expect(result.stdout.contains("\u{001B}[3m"))
        let conductorIndex = try #require(result.stdout.range(of: "Conductor — drive visible Codex and Claude")?.lowerBound)
        let artifactsIndex = try #require(result.stdout.range(of: "Artifact panes")?.lowerBound)
        let passkeysIndex = try #require(result.stdout.range(of: "Passkeys/WebAuthn")?.lowerBound)
        #expect(conductorIndex < artifactsIndex)
        #expect(artifactsIndex < passkeysIndex)
        #expect(!result.stdout.contains("Codex close-and-resume"))
        #expect(!result.stdout.contains("needs the Mochi Codex fork"))
    }

    private func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let timedOut: Bool
    }
}
