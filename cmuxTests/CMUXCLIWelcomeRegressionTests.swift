import Darwin
import Foundation
import Testing

private final class CMUXCLIWelcomeBundleToken {}

@Suite("Mochi CLI welcome", .serialized)
struct CMUXCLIWelcomeRegressionTests {
    @Test func helpAliasDoesNotResolveSocket() throws {
        let result = try runCLI(
            ["ping", "help"],
            environment: [
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CMUX_SOCKET_PATH": "/tmp/cmux-help-alias-does-not-exist.sock",
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("Usage: cmux ping"))
        #expect(!result.output.lowercased().contains("socket not found"))
    }

    @Test func welcomePublishesAuditedForkFeatureCatalog() throws {
        let result = try runCLI(
            ["welcome"],
            environment: ["CMUX_CLI_SENTRY_DISABLED": "1"]
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        for expected in [
            "Reopen last closed tab/workspace",
            "Session continuity",
            "Account-free iPhone access",
            "pair by QR over Tailscale",
            "Resource Monitor",
            "full-area Task Manager",
            "surface-pinned send/submit/wait",
            "Artifact panes",
            "adaptive right-side pane placement",
            "Privacy Frost",
            "redact their sidebar content",
            "no Pro plan or upgrade prompts",
        ] {
            #expect(result.output.contains(expected), Comment(rawValue: "Missing \(expected)\n\(result.output)"))
        }
        #expect(result.output.contains("\u{001B}[3m"))
        #expect(!result.output.contains("serve-web"))
        #expect(!result.output.contains("Claude browser"))
    }

    @Test func welcomeJSONPublishesStableFeatureIdentifiers() throws {
        let result = try runCLI(
            ["welcome", "--json"],
            environment: ["CMUX_CLI_SENTRY_DISABLED": "1"]
        )

        #expect(!result.timedOut, Comment(rawValue: result.output))
        #expect(result.status == 0, Comment(rawValue: result.output))
        let data = try #require(result.output.data(using: .utf8))
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["schema_version"] as? Int == 1)
        let featureIDs = try #require(payload["feature_ids"] as? [String])
        #expect(Set(featureIDs) == Set([
            "agent.resume-continuity",
            "artifacts.panes",
            "capture.workspace",
            "conductor.agent-settle-wait",
            "conductor.atomic-submit",
            "conductor.live-job-guard",
            "files.backed-tab-actions",
            "fork.no-pro-upsell",
            "mobile.account-free-pairing",
            "mobile.reconnect-continuity",
            "navigation.reopen-closed",
            "navigation.sidebar-spring-load",
            "pane.zoom-persistence",
            "placement.adaptive-right",
            "privacy.frost",
            "session.force-quit-continuity",
            "shell.safe-resume-aliases",
            "sidebar.render-stability",
            "task.resource-monitor",
        ]))
        #expect(featureIDs == featureIDs.sorted())

        // Cross-file ledger coverage is enforced by check-fork-parity-validation.py.
        // App-hosted tests must not read the source checkout because Documents-folder
        // privacy mediation can block that access and turn a deterministic CLI test
        // into a host-machine permission prompt.
    }

    private func runCLI(
        _ arguments: [String],
        environment: [String: String]
    ) throws -> ProcessResult {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: CMUXCLIWelcomeBundleToken.self
        )
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let timedOut = exited.wait(timeout: .now() + 5) == .timedOut
        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        return ProcessResult(
            status: process.terminationStatus,
            output: String(
                data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            timedOut: timedOut
        )
    }

    private struct ProcessResult {
        let status: Int32
        let output: String
        let timedOut: Bool
    }
}
