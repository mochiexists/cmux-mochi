import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testLegacyCodexHookAliasIsRejected() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-legacy-codex-hook-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = makeSocketPath("legacy-codex")
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")
        environment["CMUX_AGENT_HOOK_STATE_DIR"] = root.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["codex-hook", "session-start"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0, result.stdout)

        let storeURL = root.appendingPathComponent("codex-hook-sessions.json", isDirectory: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    }

    func testLegacyFeedHookAliasIsRejected() throws {
        let cliPath = try bundledCLIPath()
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = makeSocketPath("legacy-feed")
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["feed-hook", "--source", "codex"],
            environment: environment,
            standardInput: #"{"hook_event_name":"UserPromptSubmit","session_id":"legacy-feed"}"#,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertNotEqual(result.status, 0, result.stdout)
    }
}
