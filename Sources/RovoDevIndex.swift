import CMUXAgentLaunch
import Foundation

extension SessionIndexStore {
    /// Rovo Dev's sessions folder; inside the sandbox under XCTest.
    nonisolated static func defaultRovoDevSessionsRoot() -> String {
        XCTestHostHygiene.userHomePath(".rovodev/sessions")
    }

    nonisolated static func loadRovoDevEntries(
        needle: String,
        cwdFilter: String?,
        offset: Int,
        limit: Int,
        errorBag: ErrorBag,
        sessionsRoot: String = defaultRovoDevSessionsRoot()
    ) -> [SessionEntry] {
        let result = RovoDevIndex.loadSessions(
            needle: needle,
            cwdFilter: cwdFilter,
            offset: offset,
            limit: limit,
            sessionsRoot: sessionsRoot
        )
        for error in result.errors {
            errorBag.add(error)
        }
        return result.sessions.map { session in
            SessionEntry(
                id: "rovodev:" + session.sessionId,
                agent: .rovodev,
                sessionId: session.sessionId,
                title: session.title,
                cwd: session.workspacePath,
                gitBranch: nil,
                pullRequest: nil,
                modified: session.modified,
                fileURL: session.sessionContextURL,
                specifics: .rovodev
            )
        }
    }

    #if DEBUG
    nonisolated static func loadRovoDevEntriesForTesting(
        sessionsRoot: String,
        needle: String = "",
        cwdFilter: String? = nil,
        offset: Int = 0,
        limit: Int = 100
    ) -> SearchOutcome {
        let bag = ErrorBag()
        let entries = loadRovoDevEntries(
            needle: needle,
            cwdFilter: cwdFilter,
            offset: offset,
            limit: limit,
            errorBag: bag,
            sessionsRoot: sessionsRoot
        )
        return SearchOutcome(entries: entries, errors: bag.snapshot())
    }
    #endif
}
