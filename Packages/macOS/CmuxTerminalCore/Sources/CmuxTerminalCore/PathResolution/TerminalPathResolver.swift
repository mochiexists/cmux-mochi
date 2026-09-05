public import Foundation

/// Resolves file-system paths out of raw terminal text.
///
/// This is the shared path heuristics layer behind cmd-click QuickLook,
/// "open file at cursor", and terminal link opening. Candidate spellings come
/// from the pure `String` transforms in this domain (shell-token unquoting
/// and unescaping, trailing-punctuation trimming, visible-line
/// tokenization); the resolver expands them for `~`, resolves relative
/// candidates against the surface cwd and matching cwd ancestors,
/// standardizes, and probes in order.
///
/// The resolver is an instantiated value because resolution is pure only up
/// to the file system: every resolve probes candidates for existence, so the
/// file-existence capability is injected at init. Production uses the real
/// file system; tests inject a fake probe. This mirrors
/// ``TerminalLinkRouter``'s injected `BrowserHostNormalizing` seam.
public struct TerminalPathResolver: Sendable {
    private let fileExists: @Sendable (String) -> Bool
    private let isDirectory: @Sendable (String) -> Bool

    /// Creates a resolver that probes candidate paths through `fileExists`.
    ///
    /// - Parameter fileExists: The file-existence capability; defaults to the
    ///   real file system. `isDirectory` excludes directories from reconstructed
    ///   multiline file candidates and defaults to the real file system.
    public init(
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isDirectory: @escaping @Sendable (String) -> Bool = { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }
    ) {
        self.fileExists = fileExists
        self.isDirectory = isDirectory
    }

    /// Resolves raw terminal text to an existing file path for QuickLook.
    ///
    /// Candidates are derived from the raw text (as-is, shell-unescaped,
    /// shell-unquoted, and trailing-punctuation-trimmed variants), expanded
    /// for `~`, resolved against `cwd` when relative, with a fallback for
    /// repository-relative paths whose leading directory already appears in
    /// `cwd`, standardized, and probed in order. The first existing path wins.
    ///
    /// - Parameters:
    ///   - rawText: The raw text under the cursor or selection.
    ///   - cwd: The surface's working directory used for relative candidates.
    /// - Returns: The first existing standardized path, or `nil`.
    public func resolveQuicklookPath(_ rawText: String, cwd: String?) -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var seenPaths: Set<String> = []
        for token in trimmed.pathResolutionCandidates() {
            let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedToken.isEmpty else { continue }

            let expandedToken = (normalizedToken as NSString).expandingTildeInPath
            if expandedToken.hasPrefix("/") {
                if let resolvedPath = firstExistingPath(in: [expandedToken], seenPaths: &seenPaths) {
                    return resolvedPath
                }
            } else {
                guard let cwd, !cwd.isEmpty else { continue }
                if let resolvedPath = firstExistingPath(
                    in: relativeCandidatePaths(for: expandedToken, cwd: cwd),
                    seenPaths: &seenPaths
                ) {
                    return resolvedPath
                }
            }
        }

        return nil
    }

    /// Resolves the path token under a column of a visible terminal line.
    ///
    /// Tries the raw whitespace-delimited segment around the column first,
    /// then the shell-escape-aware token, and resolves each through
    /// ``resolveQuicklookPath(_:cwd:)``.
    ///
    /// - Parameters:
    ///   - line: The visible line text.
    ///   - column: The zero-based column under the cursor.
    ///   - cwd: The surface's working directory.
    /// - Returns: The raw token plus its resolved path, or `nil`.
    public func resolveVisibleLinePath(
        _ line: String,
        column: Int,
        cwd: String
    ) -> (rawToken: String, path: String)? {
        for rawToken in line.pathTokenCandidates(containingColumn: column) {
            if let resolvedPath = resolveQuicklookPath(rawToken, cwd: cwd) {
                return (rawToken, resolvedPath)
            }
        }
        return nil
    }

    /// Resolves the clicked row first, then a rooted path hard-wrapped after
    /// a slash onto at most two indented continuation rows. Filesystem evidence
    /// is required; independent roots, schemes, and unrelated prose stay separate.
    public func resolveVisiblePath(
        _ lines: [String],
        row: Int,
        column: Int,
        cwd: String
    ) -> (rawToken: String, path: String)? {
        guard lines.indices.contains(row) else { return nil }
        if let result = resolveVisibleLinePath(lines[row], column: column, cwd: cwd) {
            return result
        }
        let maximumRows = 3
        for startRow in max(0, row - maximumRows + 1)...row {
            let firstLine = Array(lines[startRow])
            // A rooted suffix may follow prose or an opening Markdown delimiter.
            for start in firstLine.indices where firstLine[start] == "/" {
                guard start == 0 || firstLine[start - 1].isWhitespace || "([<\"'`".contains(firstLine[start - 1]) else { continue }
                let root = String(firstLine[start...]).trimmingCharacters(in: .whitespaces)
                guard root.hasSuffix("/"), !root.contains(where: \.isWhitespace) else { continue }
                var candidate = root
                var clickedToken: String?
                if row == startRow, column >= start, column < start + root.count {
                    clickedToken = root
                }
                let lastRow = min(lines.count - 1, startRow + maximumRows - 1)
                guard startRow < lastRow else { continue }
                for nextRow in (startRow + 1)...lastRow {
                    guard candidate.hasSuffix("/") else { break }
                    let characters = Array(lines[nextRow])
                    let indentation = characters.prefix { $0 == " " || $0 == "\t" }.count
                    guard (1...16).contains(indentation) else { break }
                    let token = String(characters.dropFirst(indentation).prefix { !$0.isWhitespace })
                    guard !token.isEmpty,
                          !token.hasPrefix("/"), !token.hasPrefix("./"),
                          !token.hasPrefix("../"), !token.hasPrefix("~/"),
                          !token.hasPrefix("$"), URL(string: token)?.scheme == nil else { break }
                    candidate += token
                    if row == nextRow, column >= indentation, column < indentation + token.count {
                        clickedToken = token
                    }
                    guard nextRow >= row, let clickedToken,
                          let path = resolveQuicklookPath(candidate, cwd: cwd),
                          !isDirectory(path) else { continue }
                    return (clickedToken, path)
                }
            }
        }
        return nil
    }

    /// Only a matching scheme-less runtime fragment can use the file observed
    /// at click time. Explicit hyperlink destinations always keep their identity.
    public static func openURLMatchesVisibleToken(_ rawValue: String, token: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, URL(string: value)?.scheme == nil else { return false }
        return value.trimmingTrailingTerminalPunctuation() ==
            token.trimmingCharacters(in: .whitespacesAndNewlines).trimmingTrailingTerminalPunctuation()
    }

    /// Resolves an open-URL request payload to an existing file path.
    ///
    /// Text that parses as a URL with a scheme is never treated as a file
    /// path; everything else goes through ``resolveQuicklookPath(_:cwd:)``.
    ///
    /// - Parameters:
    ///   - rawText: The raw open-URL text from the runtime.
    ///   - cwd: The surface's working directory.
    /// - Returns: The first existing standardized path, or `nil`.
    public func resolveOpenURLFilePath(_ rawText: String, cwd: String?) -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard URL(string: trimmed)?.scheme == nil else { return nil }
        return resolveQuicklookPath(trimmed, cwd: cwd)
    }

    private func firstExistingPath(
        in candidatePaths: [String],
        seenPaths: inout Set<String>
    ) -> String? {
        for candidatePath in candidatePaths {
            let standardizedPath = (candidatePath as NSString).standardizingPath
            guard seenPaths.insert(standardizedPath).inserted else { continue }
            if fileExists(standardizedPath) {
                return standardizedPath
            }
        }
        return nil
    }

    private func relativeCandidatePaths(for token: String, cwd: String) -> [String] {
        var candidates = [(cwd as NSString).appendingPathComponent(token)]
        let pathComponents = (token as NSString).pathComponents
        guard let leadingDirectory = pathComponents.first,
              leadingDirectory != ".",
              leadingDirectory != "..",
              leadingDirectory != "~"
        else {
            return candidates
        }

        var ancestor = (cwd as NSString).standardizingPath
        while ancestor != "/", !ancestor.isEmpty {
            if (ancestor as NSString).lastPathComponent == leadingDirectory {
                let parent = (ancestor as NSString).deletingLastPathComponent
                candidates.append((parent as NSString).appendingPathComponent(token))
                break
            }
            let parent = (ancestor as NSString).deletingLastPathComponent
            guard parent != ancestor else { break }
            ancestor = parent
        }
        return candidates
    }
}
