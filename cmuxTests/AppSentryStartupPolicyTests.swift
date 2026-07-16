import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct AppSentryStartupPolicyTests {
    @Test func telemetryDisabledSkipsSentry() {
        let decision = AppSentryStartupPolicy.decision(
            telemetryEnabled: false,
            isRunningUnderXCTest: false,
            environment: [:]
        )

        #expect(!decision.shouldStart)
        #expect(decision.reason == "telemetry-disabled")
    }

    @Test func explicitDisableWinsOverExplicitEnable() {
        let decision = AppSentryStartupPolicy.decision(
            telemetryEnabled: true,
            isRunningUnderXCTest: false,
            environment: [
                "CMUX_APP_SENTRY_DISABLED": "1",
                "CMUX_APP_SENTRY_ENABLED": "1"
            ]
        )

        #expect(!decision.shouldStart)
        #expect(decision.reason == "env-disabled")
    }

    @Test func xctestSkipsSentry() {
        let decision = AppSentryStartupPolicy.decision(
            telemetryEnabled: true,
            isRunningUnderXCTest: true,
            environment: [:]
        )

        #expect(!decision.shouldStart)
        #expect(decision.reason == "xctest")
    }

    @Test func ciSkipsSentry() {
        let decision = AppSentryStartupPolicy.decision(
            telemetryEnabled: true,
            isRunningUnderXCTest: false,
            environment: ["GITHUB_ACTIONS": "true"]
        )

        #expect(!decision.shouldStart)
        #expect(decision.reason == "ci")
    }

#if DEBUG
    @Test func debugBuildSkipsSentryByDefault() {
        let decision = AppSentryStartupPolicy.decision(
            telemetryEnabled: true,
            isRunningUnderXCTest: false,
            environment: [:]
        )

        #expect(!decision.shouldStart)
        #expect(decision.reason == "debug-default")
    }
#endif

    @Test func explicitEnableAllowsDevelopmentSentryWhenNeeded() {
        let decision = AppSentryStartupPolicy.decision(
            telemetryEnabled: true,
            isRunningUnderXCTest: false,
            environment: ["CMUX_APP_SENTRY_ENABLED": "1"]
        )

        #expect(decision.shouldStart)
        #expect(decision.reason == "env-enabled")
    }
}
