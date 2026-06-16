import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CmuxSkillsBundleInstallerTests: XCTestCase {
    private var tempRoot: URL!
    private var bundledSkillsURL: URL!
    private var destinationURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-skills-test-\(UUID().uuidString)", isDirectory: true)
        bundledSkillsURL = tempRoot.appendingPathComponent("bundle/skills", isDirectory: true)
        destinationURL = tempRoot.appendingPathComponent("codex/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: bundledSkillsURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeInstaller(appBuild: String = "100") -> CmuxSkillsBundleInstaller {
        CmuxSkillsBundleInstaller(
            destinationDirectoryURL: destinationURL,
            appBuild: appBuild,
            bundledSkillsURLProvider: { [bundledSkillsURL] in bundledSkillsURL },
            expectedBundledSkillsPath: bundledSkillsURL.path
        )
    }

    private func writeBundledSkill(_ name: String, fileName: String = "SKILL.md", contents: String) throws {
        let skillDir = bundledSkillsURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try contents.write(
            to: skillDir.appendingPathComponent(fileName, isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    private func destSkillFile(_ name: String, _ fileName: String = "SKILL.md") -> URL {
        destinationURL.appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private func readDestSkill(_ name: String, _ fileName: String = "SKILL.md") throws -> String {
        try String(contentsOf: destSkillFile(name, fileName), encoding: .utf8)
    }

    // MARK: - Tests

    func testFreshInstallCopiesAllBundledSkills() throws {
        try writeBundledSkill("cmux-workspace", contents: "v1 workspace")
        try writeBundledSkill("cmux-browser", contents: "v1 browser")

        let outcome = try makeInstaller().sync()

        XCTAssertEqual(outcome.installed.sorted(), ["cmux-browser", "cmux-workspace"])
        XCTAssertTrue(outcome.updated.isEmpty)
        XCTAssertTrue(outcome.skippedUserModified.isEmpty)
        XCTAssertEqual(try readDestSkill("cmux-workspace"), "v1 workspace")
        XCTAssertEqual(try readDestSkill("cmux-browser"), "v1 browser")
    }

    func testSecondSyncWithUnchangedBundleIsNoOp() throws {
        try writeBundledSkill("cmux-workspace", contents: "v1")
        _ = try makeInstaller().sync()

        let outcome = try makeInstaller().sync()

        XCTAssertTrue(outcome.isNoOp, "Re-syncing identical content must change nothing")
    }

    func testUntouchedSkillIsUpdatedWhenBundledVersionChanges() throws {
        try writeBundledSkill("cmux-workspace", contents: "v1")
        _ = try makeInstaller(appBuild: "100").sync()

        // Ship a newer bundled version; the user never touched their copy.
        try writeBundledSkill("cmux-workspace", contents: "v2 newer")
        let outcome = try makeInstaller(appBuild: "101").sync()

        XCTAssertEqual(outcome.updated, ["cmux-workspace"])
        XCTAssertTrue(outcome.skippedUserModified.isEmpty)
        XCTAssertEqual(try readDestSkill("cmux-workspace"), "v2 newer")
    }

    func testUserModifiedSkillIsNotClobberedOnUpdate() throws {
        try writeBundledSkill("cmux-workspace", contents: "v1")
        _ = try makeInstaller(appBuild: "100").sync()

        // User hand-edits their installed copy...
        try "my local edits".write(to: destSkillFile("cmux-workspace"), atomically: true, encoding: .utf8)
        // ...then a newer bundled version ships.
        try writeBundledSkill("cmux-workspace", contents: "v2 newer")
        let outcome = try makeInstaller(appBuild: "101").sync()

        XCTAssertEqual(outcome.skippedUserModified, ["cmux-workspace"])
        XCTAssertTrue(outcome.updated.isEmpty)
        XCTAssertEqual(try readDestSkill("cmux-workspace"), "my local edits", "User edits must be preserved")
    }

    func testPreexistingUnmanagedSkillIsLeftUntouchedAndSilent() throws {
        // A skill already on disk (e.g. from a manual skills.sh run) with no manifest
        // record and contents differing from the bundle must not be overwritten, and
        // must NOT be reported as a user edit (that notification would be misleading
        // on the first rollout to existing skills.sh users).
        let skillDir = destinationURL.appendingPathComponent("cmux-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "pre-existing".write(to: destSkillFile("cmux-workspace"), atomically: true, encoding: .utf8)

        try writeBundledSkill("cmux-workspace", contents: "bundled version")
        let outcome = try makeInstaller().sync()

        XCTAssertEqual(outcome.skippedUnmanaged, ["cmux-workspace"])
        XCTAssertTrue(outcome.skippedUserModified.isEmpty)
        XCTAssertTrue(outcome.installed.isEmpty)
        XCTAssertEqual(try readDestSkill("cmux-workspace"), "pre-existing")
    }

    func testNewBundledSkillInstallsAlongsideExistingOnes() throws {
        try writeBundledSkill("cmux-workspace", contents: "v1")
        _ = try makeInstaller().sync()

        // A later release adds a brand-new skill.
        try writeBundledSkill("cmux-release", contents: "release skill")
        let outcome = try makeInstaller(appBuild: "101").sync()

        XCTAssertEqual(outcome.installed, ["cmux-release"])
        XCTAssertTrue(outcome.updated.isEmpty)
        XCTAssertEqual(try readDestSkill("cmux-release"), "release skill")
    }
}
