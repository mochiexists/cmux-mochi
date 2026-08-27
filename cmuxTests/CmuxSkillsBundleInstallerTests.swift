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

    func testFreshInstallCopiesEveryBundledSkill() throws {
        try writeBundledSkill("cmux-workspace", contents: "v1 workspace")
        try writeBundledSkill("cmux-browser", contents: "v1 browser")

        let outcome = try makeInstaller().sync()

        XCTAssertEqual(outcome.installed.sorted(), ["cmux-browser", "cmux-workspace"])
        XCTAssertTrue(outcome.updated.isEmpty)
        XCTAssertEqual(try readDestinationSkill("cmux-workspace"), "v1 workspace")
        XCTAssertEqual(try readDestinationSkill("cmux-browser"), "v1 browser")
    }

    func testUnchangedSecondSyncIsNoOp() throws {
        try writeBundledSkill("cmux-workspace", contents: "v1")
        _ = try makeInstaller().sync()

        XCTAssertTrue(try makeInstaller().sync().isNoOp)
    }

    func testUntouchedManagedSkillUpdatesWithBundle() throws {
        try writeBundledSkill("cmux-workspace", contents: "v1")
        _ = try makeInstaller(appBuild: "100").sync()
        try writeBundledSkill("cmux-workspace", contents: "v2")

        let outcome = try makeInstaller(appBuild: "101").sync()

        XCTAssertEqual(outcome.updated, ["cmux-workspace"])
        XCTAssertEqual(try readDestinationSkill("cmux-workspace"), "v2")
    }

    func testUserModifiedManagedSkillIsNeverClobbered() throws {
        try writeBundledSkill("cmux-workspace", contents: "v1")
        _ = try makeInstaller(appBuild: "100").sync()
        try "my local edits".write(
            to: destinationSkillFile("cmux-workspace"),
            atomically: true,
            encoding: .utf8
        )
        try writeBundledSkill("cmux-workspace", contents: "v2")

        let outcome = try makeInstaller(appBuild: "101").sync()

        XCTAssertEqual(outcome.skippedUserModified, ["cmux-workspace"])
        XCTAssertTrue(outcome.updated.isEmpty)
        XCTAssertEqual(try readDestinationSkill("cmux-workspace"), "my local edits")
    }

    func testPreexistingUnmanagedSkillIsLeftUntouched() throws {
        let skillDirectory = destinationURL.appendingPathComponent("cmux-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try "pre-existing".write(
            to: destinationSkillFile("cmux-workspace"),
            atomically: true,
            encoding: .utf8
        )
        try writeBundledSkill("cmux-workspace", contents: "bundled")

        let outcome = try makeInstaller().sync()

        XCTAssertEqual(outcome.skippedUnmanaged, ["cmux-workspace"])
        XCTAssertTrue(outcome.installed.isEmpty)
        XCTAssertEqual(try readDestinationSkill("cmux-workspace"), "pre-existing")
    }

    func testNewBundledSkillInstallsAlongsideManagedSkills() throws {
        try writeBundledSkill("cmux-workspace", contents: "v1")
        _ = try makeInstaller().sync()
        try writeBundledSkill("cmux-release", contents: "release skill")

        let outcome = try makeInstaller(appBuild: "101").sync()

        XCTAssertEqual(outcome.installed, ["cmux-release"])
        XCTAssertEqual(try readDestinationSkill("cmux-release"), "release skill")
    }

    private func makeInstaller(appBuild: String = "100") -> CmuxSkillsBundleInstaller {
        CmuxSkillsBundleInstaller(
            destinationDirectoryURL: destinationURL,
            appBuild: appBuild,
            bundledSkillsURLProvider: { [bundledSkillsURL] in bundledSkillsURL },
            expectedBundledSkillsPath: bundledSkillsURL.path
        )
    }

    private func writeBundledSkill(_ name: String, contents: String) throws {
        let skillDirectory = bundledSkillsURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try contents.write(
            to: skillDirectory.appendingPathComponent("SKILL.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    private func destinationSkillFile(_ name: String) -> URL {
        destinationURL.appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("SKILL.md", isDirectory: false)
    }

    private func readDestinationSkill(_ name: String) throws -> String {
        try String(contentsOf: destinationSkillFile(name), encoding: .utf8)
    }
}
