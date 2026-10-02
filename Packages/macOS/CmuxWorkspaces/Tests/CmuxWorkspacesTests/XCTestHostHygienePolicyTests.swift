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

    @Test func childEnvironmentNeverPointsAtTheRealHomeOrDotfiles() {
        let environment = policy.hermeticEnvironment(from: [
            "HOME": realHome,
            "ZDOTDIR": realHome,
            "XDG_CONFIG_HOME": realHome + "/.config",
            "PATH": "/opt/homebrew/bin:\(realHome)/.local/bin:/usr/bin:/bin",
            "LANG": "en_GB.UTF-8",
        ])

        for key in ["HOME", "ZDOTDIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"] {
            let value = environment[key] ?? ""
            #expect(value.hasPrefix(policy.sandboxRoot + "/"), "\(key)=\(value)")
            #expect(!value.hasPrefix(realHome), "\(key)=\(value)")
        }
        #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
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

    @Test func everyHermeticDirectoryIsCreatedInsideTheSandbox() {
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
