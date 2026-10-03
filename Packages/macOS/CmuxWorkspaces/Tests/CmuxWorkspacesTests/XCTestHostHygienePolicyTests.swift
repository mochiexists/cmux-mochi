import CmuxWorkspaces
import Testing

@Suite struct XCTestHostHygienePolicyTests {
    private let realHome = "/Users/tester"
    private let policy = XCTestHostHygienePolicy(sandboxRoot: "/private/tmp/cmux-xctest-host-42")

    @Test func detectsXCTestFromAnyInjectedMarker() {
        #expect(XCTestHostHygienePolicy.isRunningUnderXCTest(environment: ["XCTestConfigurationFilePath": "/x"]))
        #expect(XCTestHostHygienePolicy.isRunningUnderXCTest(environment: ["XCTestBundlePath": "/x"]))
        #expect(XCTestHostHygienePolicy.isRunningUnderXCTest(environment: ["XCTestSessionIdentifier": "id"]))
        #expect(!XCTestHostHygienePolicy.isRunningUnderXCTest(environment: ["HOME": realHome]))
    }

    @Test func childEnvironmentGetsAMinimalPathAndKeepsTheRest() {
        let environment = policy.hermeticEnvironment(from: [
            "HOME": realHome,
            "PATH": "/opt/homebrew/bin:\(realHome)/.local/bin:/usr/bin:/bin",
            "LANG": "en_GB.UTF-8",
        ])

        #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["HOME"] == realHome)
        #expect(environment["LANG"] == "en_GB.UTF-8")
    }

    @Test func childEnvironmentCannotReachTheDevelopersTmuxServerOrAgentConfig() {
        let environment = policy.hermeticEnvironment(from: [
            "TMUX": "/private/tmp/tmux-501/default,123,0",
            "TMUX_PANE": "%3",
            "CLAUDE_CONFIG_DIR": realHome + "/.claude",
            "CODEX_HOME": realHome + "/.codex",
        ])

        #expect(environment["TMUX"] == nil)
        #expect(environment["TMUX_PANE"] == nil)
        #expect(environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(environment["CODEX_HOME"] == nil)
        #expect(environment["TMUX_TMPDIR"] == policy.sandboxRoot + "/tmux")
    }

    @Test func agentDataReadersResolveHomeToTheSandboxWithoutAgentHomeOverrides() {
        let environment = policy.agentDataEnvironment(from: [
            "HOME": realHome,
            "HERMES_HOME": realHome + "/.hermes",
            "GROK_HOME": realHome + "/.grok",
            "CODEX_HOME": realHome + "/.codex",
            "CLAUDE_CONFIG_DIR": realHome + "/.claude",
            "LANG": "en_GB.UTF-8",
        ])

        #expect(environment["HOME"] == policy.homeDirectory)
        #expect(environment["HERMES_HOME"] == nil)
        #expect(environment["GROK_HOME"] == nil)
        #expect(environment["CODEX_HOME"] == nil)
        #expect(environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(environment["LANG"] == "en_GB.UTF-8")
    }

    @Test func everySandboxedLocationIsCreatedInsideTheSandbox() {
        let sandboxed = policy.environmentChanges.compactMap { key, value -> String? in
            guard let value, key != "PATH" else { return nil }
            return value
        }
        for path in sandboxed {
            #expect(policy.directoriesToCreate.contains(path), "\(path)")
        }
    }

    @Test func recursiveScansRefuseHomeRootAndHomeAncestors() {
        #expect(!XCTestHostHygienePolicy.allowsRecursiveScan(rootPath: realHome, realHomeDirectory: realHome))
        #expect(!XCTestHostHygienePolicy.allowsRecursiveScan(rootPath: realHome + "/", realHomeDirectory: realHome))
        #expect(!XCTestHostHygienePolicy.allowsRecursiveScan(rootPath: "/", realHomeDirectory: realHome))
        #expect(!XCTestHostHygienePolicy.allowsRecursiveScan(rootPath: "/Users", realHomeDirectory: realHome))
        #expect(!XCTestHostHygienePolicy.allowsRecursiveScan(rootPath: realHome + "/src/..", realHomeDirectory: realHome))
    }

    @Test func recursiveScansAllowProjectAndTemporaryDirectories() {
        #expect(XCTestHostHygienePolicy.allowsRecursiveScan(rootPath: realHome + "/src/cmux", realHomeDirectory: realHome))
        #expect(XCTestHostHygienePolicy.allowsRecursiveScan(rootPath: "/private/tmp/fixture", realHomeDirectory: realHome))
        #expect(XCTestHostHygienePolicy.allowsRecursiveScan(rootPath: "/Users/tester-other", realHomeDirectory: realHome))
    }
}
