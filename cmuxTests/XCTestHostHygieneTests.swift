import Foundation
import Testing
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior coverage for the unit-test host itself: these run inside the real host, so they
/// prove the hygiene policy is active before any test spawns a process or scans a folder.
@Suite struct XCTestHostHygieneTests {
    private let realHome = FileManager.default.homeDirectoryForCurrentUser.path

    @Test func testHostAppliesThePolicy() throws {
        let policy = try #require(XCTestHostHygiene.policy)
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
        #expect(policy.sandboxRoot.hasPrefix(temporaryRoot))
        for directory in policy.directoriesToCreate {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue)
        }
    }

    @Test func childProcessesInheritAHermeticEnvironment() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        var environment: [String: String] = [:]
        for line in lines {
            guard let equals = line.firstIndex(of: "=") else { continue }
            environment[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        let policy = try #require(XCTestHostHygiene.policy)

        #expect(environment["PATH"] == XCTestHostHygienePolicy.minimalPath)
        #expect(environment["TMUX"] == nil)
        #expect(environment["TMUX_PANE"] == nil)
        #expect(environment["TMUX_TMPDIR"] == policy.sandboxRoot + "/tmux")
    }

    @Test func recursiveScansRefuseTheRealHomeAndRoot() {
        #expect(!XCTestHostHygiene.allowsRecursiveScan(rootPath: realHome))
        #expect(!XCTestHostHygiene.allowsRecursiveScan(rootPath: "/"))
        #expect(XCTestHostHygiene.allowsRecursiveScan(rootPath: NSTemporaryDirectory()))
    }

    @Test func otherAppsDataIsLookedUpInsideTheSandbox() throws {
        let policy = try #require(XCTestHostHygiene.policy)
        #expect(XCTestHostHygiene.userHomeDirectoryURL.path == policy.homeDirectory)
    }

    @Test func agentCredentialsAndSessionsAreReadFromTheSandbox() throws {
        let policy = try #require(XCTestHostHygiene.policy)
        #expect(AIAccountCredentialSources().homeDirectory.path == policy.homeDirectory)
        #expect(XCTestHostHygiene.userHomePath(".codex/state_5.sqlite") == policy.homeDirectory + "/.codex/state_5.sqlite")
        #expect(!XCTestHostHygiene.userHomePath(".claude").hasPrefix(realHome + "/"))
    }

    @Test func everyAgentIndexResolvesItsDefaultPathInsideTheSandbox() throws {
        let policy = try #require(XCTestHostHygiene.policy)
        let sandboxHome = policy.homeDirectory + "/"
        let grokRoot = GrokSessionLocator.sessionRoot(
            registration: CmuxVaultAgentRegistration.builtInGrok,
            environment: [:]
        )
        let defaultPaths: [(index: String, path: String)] = [
            ("opencode", OpenCodeDatabaseSnapshot.sourcePath),
            ("hermes", SessionIndexStore.defaultHermesStateDBPath()),
            ("rovodev", SessionIndexStore.defaultRovoDevSessionsRoot()),
            ("grok", GrokSessionLocator.defaultSessionsRoot()),
            ("grok registration", grokRoot.sessionsRoot),
            ("pi", PiSessionLocator.defaultSessionsRoot()),
            ("pi registration", XCTestHostHygiene.expandingUserTilde(
                in: try #require(CmuxVaultAgentRegistration.builtInPi.sessionDirectory)
            )),
            ("campfire registration", XCTestHostHygiene.expandingUserTilde(
                in: try #require(CmuxVaultAgentRegistration.builtInCampfire.sessionDirectory)
            )),
            ("agent chat hook sessions", AgentChatHookSessionStore().homeDirectory.path + "/"),
            ("restorable hook store", RestorableAgentKind.claude.hookStoreFileURL(environment: [:]).path),
            ("turn diff baselines", AppDelegate.agentTurnDiffBaselineStoreURL().path),
            ("event log", CmuxEventBus.defaultEventLogURL().path),
            ("codex skills", CmuxSkillsBundleInstaller.defaultDestinationDirectoryURL().path),
            ("agent environment HOME", (XCTestHostHygiene.agentEnvironment["HOME"] ?? "") + "/"),
        ]
        for (index, path) in defaultPaths {
            #expect(path.hasPrefix(sandboxHome), "\(index): \(path)")
            #expect(!path.hasPrefix(realHome + "/"), "\(index): \(path)")
        }
    }

    @Test func mobileHostDoesNotBringUpIrohOnItsOwn() {
        #expect(!MobileHostService.activatesIrohAutomatically)
    }
}
