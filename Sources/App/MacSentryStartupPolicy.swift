import Foundation

struct MacSentryStartupPolicy: Sendable {
    struct Decision: Equatable, Sendable {
        let shouldStart: Bool
        let reason: String
    }

    let telemetryEnabled: Bool
    let isRunningUnderXCTest: Bool
    let allowUnderXCTest: Bool
    let startupDecision: Decision

    init(
        telemetryEnabled: Bool,
        isRunningUnderXCTest: Bool,
        allowUnderXCTest: Bool
    ) {
        self.telemetryEnabled = telemetryEnabled
        self.isRunningUnderXCTest = isRunningUnderXCTest
        self.allowUnderXCTest = allowUnderXCTest
        self.startupDecision = Self.decision(
            telemetryEnabled: telemetryEnabled,
            isRunningUnderXCTest: isRunningUnderXCTest,
            environment: allowUnderXCTest ? ["CMUX_TEST_SENTRY_ENABLED": "1"] : [:]
        )
    }

    init(
        environment: [String: String],
        telemetryEnabled: Bool
    ) {
        let isRunningUnderXCTest = Self.isRunningUnderXCTest(environment: environment)
        self.telemetryEnabled = telemetryEnabled
        self.isRunningUnderXCTest = isRunningUnderXCTest
        self.allowUnderXCTest = Self.booleanEnvironmentValue(
            "CMUX_TEST_SENTRY_ENABLED",
            in: environment
        ) == true
        self.startupDecision = Self.decision(
            telemetryEnabled: telemetryEnabled,
            isRunningUnderXCTest: isRunningUnderXCTest,
            environment: environment
        )
    }

    var shouldStart: Bool {
        startupDecision.shouldStart
    }

    static func decision(
        telemetryEnabled: Bool,
        isRunningUnderXCTest: Bool,
        environment: [String: String]
    ) -> Decision {
        guard telemetryEnabled else {
            return Decision(shouldStart: false, reason: "telemetry-disabled")
        }
        if booleanEnvironmentValue("CMUX_APP_SENTRY_DISABLED", in: environment) == true {
            return Decision(shouldStart: false, reason: "env-disabled")
        }
        if booleanEnvironmentValue("CMUX_APP_SENTRY_ENABLED", in: environment) == true
            || booleanEnvironmentValue("CMUX_TEST_SENTRY_ENABLED", in: environment) == true {
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

    static func isRunningUnderXCTest(environment: [String: String]) -> Bool {
        // xcodebuild strips TEST_RUNNER_ from variables forwarded to the test
        // host, so the CI wrapper makes this available before XCTest connects.
        if environment["CMUX_TEST_PROCESS"] == "1" { return true }
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        if environment["XCTestBundlePath"] != nil { return true }
        if environment["XCTestSessionIdentifier"] != nil { return true }
        if environment["XCInjectBundle"] != nil { return true }
        if environment["XCInjectBundleInto"] != nil { return true }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true { return true }
        if environment.keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) { return true }
        return false
    }

    private static func isCIEnvironment(_ environment: [String: String]) -> Bool {
        booleanEnvironmentValue("CI", in: environment) == true
            || booleanEnvironmentValue("GITHUB_ACTIONS", in: environment) == true
            || booleanEnvironmentValue("XCODE_CLOUD", in: environment) == true
    }

    private static func booleanEnvironmentValue(
        _ key: String,
        in environment: [String: String]
    ) -> Bool? {
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
