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

        #expect(environment["HOME"] == policy.homeDirectory)
        #expect(environment["ZDOTDIR"] == policy.homeDirectory)
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

    @Test func mobileHostDoesNotBringUpIrohOnItsOwn() {
        #expect(!MobileHostService.activatesIrohAutomatically)
    }
}
