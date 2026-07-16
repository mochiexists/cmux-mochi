import Foundation

struct AppSentryStartupPolicy {
    struct Decision: Equatable {
        let shouldStart: Bool
        let reason: String
    }

    static func decision(
        telemetryEnabled: Bool,
        isRunningUnderXCTest: Bool,
        environment: [String: String]
    ) -> Decision {
        if !telemetryEnabled {
            return Decision(shouldStart: false, reason: "telemetry-disabled")
        }
        if booleanEnvironmentValue("CMUX_APP_SENTRY_DISABLED", in: environment) == true {
            return Decision(shouldStart: false, reason: "env-disabled")
        }
        if booleanEnvironmentValue("CMUX_APP_SENTRY_ENABLED", in: environment) == true {
            return Decision(shouldStart: true, reason: "env-enabled")
        }
        if isRunningUnderXCTest {
            return Decision(shouldStart: false, reason: "xctest")
        }
        if isCIEnvironment(environment) {
            return Decision(shouldStart: false, reason: "ci")
        }

#if DEBUG
        return Decision(shouldStart: false, reason: "debug-default")
#else
        return Decision(shouldStart: true, reason: "production")
#endif
    }

    static func decision(
        telemetryEnabled: Bool,
        environment: [String: String]
    ) -> Decision {
        decision(
            telemetryEnabled: telemetryEnabled,
            isRunningUnderXCTest: isRunningUnderXCTest(environment),
            environment: environment
        )
    }

    static func isRunningUnderXCTest(_ environment: [String: String]) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        if environment["XCTestBundlePath"] != nil { return true }
        if environment["XCTestSessionIdentifier"] != nil { return true }
        if environment["XCInjectBundle"] != nil { return true }
        if environment["XCInjectBundleInto"] != nil { return true }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true { return true }
        return environment.keys.contains { $0.hasPrefix("CMUX_UI_TEST_") }
    }

    private static func isCIEnvironment(_ environment: [String: String]) -> Bool {
        booleanEnvironmentValue("CI", in: environment) == true ||
            booleanEnvironmentValue("GITHUB_ACTIONS", in: environment) == true ||
            booleanEnvironmentValue("XCODE_CLOUD", in: environment) == true
    }

    private static func booleanEnvironmentValue(_ key: String, in environment: [String: String]) -> Bool? {
        guard let rawValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        switch rawValue.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}

enum AppSentryRuntime {
    static let startupDecisionForCurrentLaunch = AppSentryStartupPolicy.decision(
        telemetryEnabled: TelemetrySettings.enabledForCurrentLaunch,
        environment: ProcessInfo.processInfo.environment
    )
    static let enabledForCurrentLaunch = startupDecisionForCurrentLaunch.shouldStart
}
