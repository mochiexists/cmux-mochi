import Foundation
import SQLite3
import Testing
@testable import CMUXAgentLaunch

@Suite struct CodexCheckpointVerifierTests {
    @Test func indexedInteractiveCheckpointProvidesDurableWorkingDirectory() throws {
        let fixture = try makeFixture(source: "cli", originator: "codex-tui")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = CodexCheckpointVerifier().verify(
            sessionID: fixture.sessionID,
            codexHome: fixture.codexHome.path,
            transcriptPath: fixture.rollout.path
        )

        #expect(result == .interactive(CodexCheckpointEvidence(
            workingDirectory: fixture.repo.path,
            rolloutPath: fixture.rollout.standardizedFileURL.path
        )))
    }

    @Test func indexedMissingCheckpointIsRejected() throws {
        let fixture = try makeFixture(source: "cli", originator: "codex-tui")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = CodexCheckpointVerifier().verify(
            sessionID: "01a05dc5-9937-7571-88c6-5fb92f6e3e7a",
            codexHome: fixture.codexHome.path,
            transcriptPath: fixture.rollout.path
        )

        #expect(result == .rejected)
    }

    @Test func indexedReviewCheckpointCannotOwnInteractiveSurface() throws {
        let fixture = try makeFixture(source: "review", originator: "codex_exec")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = CodexCheckpointVerifier().verify(
            sessionID: fixture.sessionID,
            codexHome: fixture.codexHome.path,
            transcriptPath: fixture.rollout.path
        )

        #expect(result == .rejected)
    }

    @Test func unindexedLegacyInstallPreservesFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-unindexed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyTranscript = root.appendingPathComponent("rollout-legacy.jsonl")
        try #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
            .write(to: legacyTranscript, atomically: true, encoding: .utf8)

        let result = CodexCheckpointVerifier().verify(
            sessionID: "legacy-session",
            codexHome: root.path,
            transcriptPath: legacyTranscript.path
        )

        #expect(result == .legacyUnindexed)
    }

    private struct Fixture {
        let root: URL
        let codexHome: URL
        let repo: URL
        let rollout: URL
        let sessionID: String
    }

    private func makeFixture(source: String, originator: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-checkpoint-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        let repo = root.appendingPathComponent("project", isDirectory: true)
        let sessions = codexHome.appendingPathComponent("sessions/2026/09/02", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        let sessionID = "01a0301e-a104-7221-91ac-e347087c136c"
        let rollout = sessions.appendingPathComponent("rollout-\(sessionID).jsonl")
        let metadata: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "id": sessionID,
                "cwd": repo.path,
                "source": source,
                "originator": originator,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        try (String(decoding: data, as: UTF8.self) + "\n")
            .write(to: rollout, atomically: true, encoding: .utf8)

        let database = codexHome.appendingPathComponent("state_5.sqlite")
        try createDatabase(at: database)
        try insertThread(
            at: database,
            sessionID: sessionID,
            rolloutPath: rollout.path,
            source: source
        )
        return Fixture(
            root: root,
            codexHome: codexHome,
            repo: repo,
            rollout: rollout,
            sessionID: sessionID
        )
    }

    private func createDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw NSError(domain: "CodexCheckpointFixture", code: 1)
        }
        defer { sqlite3_close(database) }
        let schema = "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, source TEXT, thread_source TEXT)"
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "CodexCheckpointFixture", code: 2)
        }
    }

    private func insertThread(
        at url: URL,
        sessionID: String,
        rolloutPath: String,
        source: String
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw NSError(domain: "CodexCheckpointFixture", code: 3)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO threads (id, rollout_path, source, thread_source) VALUES (?, ?, ?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw NSError(domain: "CodexCheckpointFixture", code: 4)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, sessionID, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 2, rolloutPath, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 3, source, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 4, source, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "CodexCheckpointFixture", code: 5)
        }
    }
}
