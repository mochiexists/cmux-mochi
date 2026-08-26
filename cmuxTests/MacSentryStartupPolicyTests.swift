import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct MacSentryStartupPolicyTests {
    @Test func xctestLaunchDoesNotStartSentry() {
        #expect(
            MacSentryStartupPolicy(
                telemetryEnabled: true,
                isRunningUnderXCTest: true,
                allowUnderXCTest: false
            ).shouldStart == false
        )
    }

    @Test func explicitTestTelemetryOptInStartsSentry() {
        #expect(
            MacSentryStartupPolicy(
                telemetryEnabled: true,
                isRunningUnderXCTest: true,
                allowUnderXCTest: true
            ).shouldStart == true
        )
    }

    @Test func telemetryDisabledWinsOverExplicitEnable() {
        #expect(
            MacSentryStartupPolicy(
                environment: ["CMUX_APP_SENTRY_ENABLED": "1"],
                telemetryEnabled: false
            ).startupDecision == .init(
                shouldStart: false,
                reason: "telemetry-disabled"
            )
        )
    }

    @Test func explicitDisableWinsOverExplicitEnable() {
        #expect(
            MacSentryStartupPolicy(
                environment: [
                    "CMUX_APP_SENTRY_DISABLED": "1",
                    "CMUX_APP_SENTRY_ENABLED": "1",
                ],
                telemetryEnabled: true
            ).startupDecision == .init(
                shouldStart: false,
                reason: "env-disabled"
            )
        )
    }

#if DEBUG
    @Test func normalDebugLaunchSkipsSentry() {
        #expect(
            MacSentryStartupPolicy(
                telemetryEnabled: true,
                isRunningUnderXCTest: false,
                allowUnderXCTest: false
            ).startupDecision == .init(
                shouldStart: false,
                reason: "debug-default"
            )
        )
    }
#else
    @Test func normalProductionLaunchStartsSentry() {
        #expect(
            MacSentryStartupPolicy(
                telemetryEnabled: true,
                isRunningUnderXCTest: false,
                allowUnderXCTest: false
            ).startupDecision == .init(
                shouldStart: true,
                reason: "production"
            )
        )
    }
#endif

    @Test func telemetryOptOutStillPreventsSentryStartup() {
        #expect(
            MacSentryStartupPolicy(
                telemetryEnabled: false,
                isRunningUnderXCTest: false,
                allowUnderXCTest: false
            ).shouldStart == false
        )
    }

    @Test func explicitUITestMarkerPreventsSentryStartup() {
        #expect(
            MacSentryStartupPolicy(
                environment: ["CMUX_UI_TEST_PROCESS": "1"],
                telemetryEnabled: true
            ).shouldStart == false
        )
    }

    @Test func testRunnerMarkerPreventsSentryStartup() {
        #expect(
            MacSentryStartupPolicy(
                environment: ["CMUX_TEST_PROCESS": "1"],
                telemetryEnabled: true
            ).shouldStart == false
        )
    }

    @Test func explicitTestTelemetryOptInOverridesUITestMarker() {
        #expect(
            MacSentryStartupPolicy(
                environment: [
                    "CMUX_UI_TEST_PROCESS": "1",
                    "CMUX_TEST_SENTRY_ENABLED": "1"
                ],
                telemetryEnabled: true
            ).shouldStart == true
        )
    }

    @Test func explicitAppOptInOverridesUITestMarker() {
        #expect(
            MacSentryStartupPolicy(
                environment: [
                    "CMUX_UI_TEST_PROCESS": "1",
                    "CMUX_APP_SENTRY_ENABLED": "yes",
                ],
                telemetryEnabled: true
            ).startupDecision == .init(
                shouldStart: true,
                reason: "env-enabled"
            )
        )
    }

    @Test(arguments: ["CI", "GITHUB_ACTIONS", "XCODE_CLOUD"])
    func ciLaunchSkipsSentry(marker: String) {
        #expect(
            MacSentryStartupPolicy(
                environment: [marker: "true"],
                telemetryEnabled: true
            ).startupDecision == .init(
                shouldStart: false,
                reason: "ci"
            )
        )
    }
}
