import Foundation
import SQLite3

public struct CodexCheckpointEvidence: Equatable, Sendable {
    public let workingDirectory: String?
    public let rolloutPath: String

    public init(workingDirectory: String?, rolloutPath: String) {
        self.workingDirectory = workingDirectory
        self.rolloutPath = rolloutPath
    }
}

public enum CodexCheckpointVerification: Equatable, Sendable {
    /// No Codex index exists. Preserve the legacy argv/transcript fallback.
    case legacyUnindexed
    /// The requested id belongs to an interactive, durable Codex rollout.
    case interactive(CodexCheckpointEvidence)
    /// An index exists, but the id is absent, non-interactive, or no longer durable.
    case rejected
}

/// Verifies a saved Codex id before cmux lets it own or resume a terminal surface.
///
/// Codex can expose short-lived review/subagent ids through process environment and
/// transcript text. Those ids are not necessarily resumable. The state database and
/// rollout metadata are the durable authority; when they exist, cmux must not fall
/// back to a transient process id or cwd.
public struct CodexCheckpointVerifier {
    private static let maximumRolloutBytes = 256 * 1024
    private static let maximumDatabaseCount = 8

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func codexHome(
        launchEnvironment: [String: String]?,
        fallbackHomeDirectory: String
    ) -> String {
        if let configured = normalized(launchEnvironment?["CODEX_HOME"]) {
            return (configured as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: fallbackHomeDirectory, isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL.path
    }

    public func verify(
        sessionID: String,
        codexHome: String,
        transcriptPath: String?
    ) -> CodexCheckpointVerification {
        guard let sessionID = normalized(sessionID), isSafeSessionID(sessionID) else {
            return .rejected
        }
        let homeURL = URL(fileURLWithPath: codexHome, isDirectory: true).standardizedFileURL
        let databases = stateDatabases(in: homeURL)

        if databases.isEmpty {
            // Older Codex installs and imported cmux snapshots have no state
            // database, and some valid legacy transcripts predate session_meta.
            return .legacyUnindexed
        }

        for database in databases {
            switch indexedRecord(sessionID: sessionID, databaseURL: database) {
            case .unreadable:
                continue
            case .missing:
                continue
            case .record(let record):
                if sourceIsNonInteractive(record.source)
                    || sourceIsNonInteractive(record.threadSource) {
                    return .rejected
                }
                let candidates = [record.rolloutPath, transcriptPath]
                    .compactMap(normalized)
                    .map(expandedURL(path:))
                for candidate in candidates {
                    if let verification = verificationFromRollout(
                        at: candidate,
                        requestedSessionID: sessionID,
                        indexedSource: record.source,
                        indexedThreadSource: record.threadSource
                    ) {
                        return verification
                    }
                }
                return .rejected
            }
        }
        return .rejected
    }

    private enum IndexedLookup {
        case record(IndexedRecord)
        case missing
        case unreadable
    }

    private struct IndexedRecord {
        let rolloutPath: String?
        let source: String?
        let threadSource: String?
    }

    private func stateDatabases(in homeURL: URL) -> [URL] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: homeURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return children
            .filter {
                $0.lastPathComponent.hasPrefix("state_")
                    && $0.pathExtension.lowercased() == "sqlite"
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(Self.maximumDatabaseCount)
            .map { $0 }
    }

    private func indexedRecord(sessionID: String, databaseURL: URL) -> IndexedLookup {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return .unreadable
        }
        defer { sqlite3_close(database) }

        let queries = [
            "SELECT rollout_path, source, thread_source FROM threads WHERE id = ? LIMIT 1",
            "SELECT rollout_path, source, NULL FROM threads WHERE id = ? LIMIT 1",
            "SELECT rollout_path, NULL, NULL FROM threads WHERE id = ? LIMIT 1",
        ]
        for query in queries {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                sqlite3_finalize(statement)
                continue
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(
                OpaquePointer(bitPattern: -1),
                to: sqlite3_destructor_type.self
            )
            guard sqlite3_bind_text(statement, 1, sessionID, -1, transient) == SQLITE_OK else {
                return .unreadable
            }
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                return .record(IndexedRecord(
                    rolloutPath: sqliteText(statement, column: 0),
                    source: sqliteText(statement, column: 1),
                    threadSource: sqliteText(statement, column: 2)
                ))
            case SQLITE_DONE:
                return .missing
            default:
                continue
            }
        }
        return .unreadable
    }

    private func verificationFromRollout(
        at url: URL,
        requestedSessionID: String,
        indexedSource: String?,
        indexedThreadSource: String?
    ) -> CodexCheckpointVerification? {
        guard fileManager.isReadableFile(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maximumRolloutBytes),
              !data.isEmpty else {
            return nil
        }

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any],
                  normalized(payload["id"] as? String) == requestedSessionID else {
                continue
            }
            let metadataSource = serialized(payload["source"])
            let originator = normalized(payload["originator"] as? String)
            if sourceIsNonInteractive(indexedSource)
                || sourceIsNonInteractive(indexedThreadSource)
                || sourceIsNonInteractive(metadataSource)
                || sourceIsNonInteractive(originator) {
                return .rejected
            }
            return .interactive(CodexCheckpointEvidence(
                workingDirectory: normalized(payload["cwd"] as? String),
                rolloutPath: url.standardizedFileURL.path
            ))
        }
        return nil
    }

    private func sourceIsNonInteractive(_ rawValue: String?) -> Bool {
        guard let source = normalized(rawValue)?.lowercased() else { return false }
        return ["review", "subagent", "sub_agent", "compact", "codex_exec"]
            .contains { source.contains($0) }
    }

    private func serialized(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let value = value as? String {
            return value
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return String(describing: value)
        }
        return String(data: data, encoding: .utf8)
    }

    private func expandedURL(path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: false)
            .standardizedFileURL
    }

    private func sqliteText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, column) else {
            return nil
        }
        return normalized(String(cString: text))
    }

    private func isSafeSessionID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
