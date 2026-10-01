import Foundation

/// Prevents Debug app defaults from opening a workspace at the user's home or filesystem root.
public struct DefaultWorkspaceWorkingDirectoryPolicy: Sendable {
    private let isDebugBuild: Bool
    private let homeDirectory: String
    private let repositoryRoot: String?
    private let scratchDirectory: String

    /// Creates a working-directory safety policy for an app build.
    ///
    /// - Parameters:
    ///   - isDebugBuild: Whether the caller is a Debug build that requires the safety guard.
    ///   - homeDirectory: The current user's home directory.
    ///   - repositoryRoot: The optional repository root supplied by the launch environment.
    ///   - scratchDirectory: An existing, dedicated directory safe for Debug workspaces.
    public init(
        isDebugBuild: Bool,
        homeDirectory: String,
        repositoryRoot: String?,
        scratchDirectory: String
    ) {
        self.isDebugBuild = isDebugBuild
        self.homeDirectory = homeDirectory
        self.repositoryRoot = repositoryRoot
        self.scratchDirectory = scratchDirectory
    }

    /// Resolves a candidate directory while preserving Release behavior.
    ///
    /// Safe explicit directories pass through unchanged. In Debug builds, a candidate that
    /// resolves to the user's home or `/` is replaced by an existing repository root when
    /// available, otherwise by the dedicated scratch directory.
    ///
    /// - Parameters:
    ///   - candidate: The directory selected by normal workspace precedence.
    ///   - directoryExists: Returns whether an absolute path names an existing directory.
    /// - Returns: The directory to use for the workspace.
    public func resolve(
        candidate: String,
        directoryExists: (String) -> Bool
    ) -> String {
        guard isDebugBuild, isUnsafeDefault(candidate) else {
            return candidate
        }

        if let repositoryRoot = normalizedAbsolutePath(repositoryRoot),
           !isUnsafeDefault(repositoryRoot),
           directoryExists(repositoryRoot) {
            return repositoryRoot
        }

        return normalizedAbsolutePath(scratchDirectory) ?? scratchDirectory
    }

    private func isUnsafeDefault(_ path: String) -> Bool {
        guard let normalizedPath = normalizedAbsolutePath(path) else {
            return false
        }
        return normalizedPath == "/"
            || normalizedPath == normalizedAbsolutePath(homeDirectory)
    }

    private func normalizedAbsolutePath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (trimmed as NSString).isAbsolutePath else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}
