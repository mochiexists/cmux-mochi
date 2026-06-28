import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("ArtifactStore")
struct ArtifactStoreTests {
    /// 2026-06-28T14:30:22Z as a fixed instant for deterministic path/record tests.
    private var fixedDate: Date {
        Date(timeIntervalSince1970: 1_782_657_022)
    }

    // MARK: - slugify

    @Test func slugifyLowercasesAndHyphenates() {
        #expect(ArtifactStore.slugify("Pricing Table") == "pricing-table")
    }

    @Test func slugifyCollapsesNonAlphanumericRuns() {
        #expect(ArtifactStore.slugify("Foo!!  Bar / Baz") == "foo-bar-baz")
    }

    @Test func slugifyTrimsLeadingAndTrailingSeparators() {
        #expect(ArtifactStore.slugify("  --Hello--  ") == "hello")
    }

    @Test func slugifyFallsBackForEmptyResult() {
        #expect(ArtifactStore.slugify("!!!") == "artifact")
        #expect(ArtifactStore.slugify("") == "artifact")
    }

    @Test func slugifyCapsLength() {
        let slug = ArtifactStore.slugify(String(repeating: "a", count: 100), maxLength: 10)
        #expect(slug.count == 10)
    }

    // MARK: - relativePath

    @Test func relativePathBucketsByUTCDate() {
        let path = ArtifactStore.relativePath(
            createdAt: fixedDate,
            slug: "pricing-table",
            shortID: "a1b2c3d4",
            fileExtension: "tsx"
        )
        #expect(path == "2026/06/28/20260628-143022-pricing-table-a1b2c3d4.tsx")
    }

    // MARK: - makeRecord

    @Test func makeRecordSlugsTitleAndStampsISO8601() {
        let record = ArtifactStore.makeRecord(
            id: "a1b2c3d4",
            createdAt: fixedDate,
            title: "Pricing Table",
            kind: .react,
            origin: ArtifactOrigin(cwd: "/tmp/foo", repoRoot: "/tmp/foo")
        )
        #expect(record.createdAt == "2026-06-28T14:30:22Z")
        #expect(record.file == "2026/06/28/20260628-143022-pricing-table-a1b2c3d4.tsx")
        #expect(record.kind == .react)
        #expect(record.origin.repoRoot == "/tmp/foo")
    }

    @Test func reactKindUsesTsxExtension() {
        #expect(ArtifactKind.react.fileExtension == "tsx")
        #expect(ArtifactKind.swiftui.fileExtension == "swift")
    }

    // MARK: - default root + override

    @Test func defaultRootPathHonorsOverride() {
        let defaults = UserDefaults(suiteName: "artifact-store-test-override")!
        defaults.removePersistentDomain(forName: "artifact-store-test-override")
        defaults.set("~/scratch/arts", forKey: "artifacts.directory")
        let root = ArtifactStore.defaultRootPath(defaults: defaults)
        #expect(root.hasSuffix("/scratch/arts"))
        #expect(!root.hasPrefix("~"))
    }

    @Test func defaultRootPathFallsBackToConfigDir() {
        let defaults = UserDefaults(suiteName: "artifact-store-test-fallback")!
        defaults.removePersistentDomain(forName: "artifact-store-test-fallback")
        let root = ArtifactStore.defaultRootPath(defaults: defaults)
        #expect(root.hasSuffix(".config/cmux/artifacts"))
    }

    // MARK: - disk round-trip

    @Test func createWritesFileAndAppendsIndex() throws {
        let tempRoot = NSTemporaryDirectory() + "artifact-store-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let store = ArtifactStore(rootPath: tempRoot)

        let record = ArtifactStore.makeRecord(
            id: "deadbeef",
            createdAt: fixedDate,
            title: "Hello World",
            kind: .react,
            origin: ArtifactOrigin(cwd: "/tmp/x")
        )
        let absolute = try store.create(scaffold: "export default () => null;", record: record)

        #expect(FileManager.default.fileExists(atPath: absolute))
        let written = try String(contentsOfFile: absolute, encoding: .utf8)
        #expect(written.contains("export default"))

        let records = store.listRecords()
        #expect(records.count == 1)
        #expect(records.first == record)
    }

    @Test func listRecordsSkipsMalformedLines() throws {
        let tempRoot = NSTemporaryDirectory() + "artifact-store-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let store = ArtifactStore(rootPath: tempRoot)

        let record = ArtifactStore.makeRecord(
            id: "feedface",
            createdAt: fixedDate,
            title: "Valid",
            kind: .react,
            origin: ArtifactOrigin()
        )
        try store.appendToIndex(record)
        // Corrupt line between valid ones.
        let handle = FileHandle(forWritingAtPath: store.indexPath)!
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{ not json\n".utf8))
        try handle.close()
        try store.appendToIndex(record)

        #expect(store.listRecords().count == 2)
    }
}
