import Foundation

/// Keeps the app's unit-test host away from the developer's home folder, private data and tools.
///
/// The Debug app doubles as the `xcodebuild test` host. Without this policy its child
/// processes inherit the developer's real `HOME`, `PATH` and tmux server, so a test that
/// spawns a shell runs the developer's dotfiles, can start real agent CLIs, and the cmux
/// shell integration publishes the test host's socket into the developer's tmux server.
/// Scans rooted at the home folder or `/` (file search, mention indexing) also make macOS
/// raise privacy prompts for Music, Photos, Desktop, Documents and Downloads.
public struct XCTestHostHygienePolicy: Sendable, Equatable {
    /// The `PATH` handed to every child process of the test host.
    public static let minimalPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Variables removed from the test host's environment so children cannot reach the
    /// developer's tmux server or agent configuration.
    public static let removedEnvironmentKeys = [
        "TMUX",
        "TMUX_PANE",
        "CLAUDE_CONFIG_DIR",
        "CODEX_HOME",
    ]

    /// The private directory that holds every hermetic location.
    public let sandboxRoot: String

    /// Creates a policy rooted at a private, per-run directory.
    ///
    /// - Parameter sandboxRoot: An absolute path owned by this test-host process.
    public init(sandboxRoot: String) {
        self.sandboxRoot = URL(fileURLWithPath: sandboxRoot).standardizedFileURL.path
    }

    /// Whether the current process is an XCTest host.
    ///
    /// - Parameter environment: The process environment.
    /// - Returns: `true` when XCTest injected its configuration into the process.
    public static func isRunningUnderXCTest(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }

    /// The home folder in-process readers of other apps' and agents' data use.
    public var homeDirectory: String { sandboxRoot + "/home" }

    /// Directories that must exist before the environment is applied.
    public var directoriesToCreate: [String] {
        [
            homeDirectory,
            homeDirectory + "/.config",
            homeDirectory + "/.local/share",
            homeDirectory + "/.cache",
            homeDirectory + "/.local/state",
            sandboxRoot + "/tmux",
        ]
    }

    /// The environment changes for the test host: a value sets the key, `nil` removes it.
    ///
    /// `HOME` and the XDG variables are deliberately left alone: libghostty runs inside
    /// the host and resolves its own config from them, so redirecting them splits the
    /// in-process terminal config from the Swift-side config. In-process readers of other
    /// apps' and agents' data use ``homeDirectory`` instead.
    public var environmentChanges: [String: String?] {
        var changes: [String: String?] = [
            "TMUX_TMPDIR": sandboxRoot + "/tmux",
            "PATH": Self.minimalPath,
        ]
        for key in Self.removedEnvironmentKeys {
            changes[key] = .some(nil)
        }
        return changes
    }

    /// Applies ``environmentChanges`` to an environment dictionary.
    ///
    /// - Parameter environment: The inherited environment.
    /// - Returns: The hermetic environment for a child process.
    public func hermeticEnvironment(from environment: [String: String]) -> [String: String] {
        var result = environment
        for (key, value) in environmentChanges {
            result[key] = value
        }
        return result
    }

    /// Whether a recursive scan may start at `path`.
    ///
    /// The developer's home folder, `/`, and any ancestor of the home folder are refused.
    ///
    /// - Parameters:
    ///   - path: The scan root.
    ///   - realHomeDirectory: The developer's real home folder.
    /// - Returns: `false` for roots that would walk the developer's private folders.
    public static func allowsRecursiveScan(rootPath path: String, realHomeDirectory: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (trimmed as NSString).isAbsolutePath else { return true }
        let root = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        let home = URL(fileURLWithPath: realHomeDirectory).standardizedFileURL.path
        if root == "/" || root == home { return false }
        return !(home.hasPrefix(root + "/"))
    }
}
