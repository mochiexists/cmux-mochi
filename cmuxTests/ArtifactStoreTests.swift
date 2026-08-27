import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Artifact store parity", .serialized)
struct ArtifactStoreTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_782_657_022)

    @Test func kindCompatibilityMatrixIsStable() {
        #expect(ArtifactKind.kind(forFileExtension: "TSX") == .react)
        #expect(ArtifactKind.kind(forFileExtension: "html") == .html)
        #expect(ArtifactKind.kind(forFileExtension: "svg") == .svg)
        #expect(ArtifactKind.kind(forFileExtension: "mmd") == .mermaid)
        #expect(ArtifactKind.kind(forFileExtension: "swift") == .code)
        #expect(ArtifactKind.kind(forFileExtension: "pdf") == .file)
        #expect(ArtifactKind.kind(forFileExtension: "md") == nil)
        #expect(ArtifactKind.react.rendersInWebView)
        #expect(!ArtifactKind.file.rendersInWebView)
        #expect(!ArtifactKind.file.requiresTextSource)
    }

    @Test func createListAndResolvePreserveProvenance() throws {
        let root = temporaryRoot(named: "artifact-store")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = ArtifactStore(rootPath: root)
        let origin = ArtifactOrigin(
            cwd: "/tmp/project",
            repoRoot: "/tmp/project",
            workspaceId: "workspace-1",
            surfaceId: "surface-1"
        )

        let created = try store.createNew(
            title: "Pricing Table",
            kind: .react,
            origin: origin,
            source: "export default function Pricing() { return null }",
            now: fixedDate,
            shortID: "a1b2c3d4"
        )

        #expect(created.record.createdAt == "2026-06-28T14:30:22Z")
        #expect(created.record.file == "2026/06/28/20260628-143022-pricing-table-a1b2c3d4.tsx")
        #expect(created.record.origin == origin)
        #expect(try String(contentsOfFile: created.path, encoding: .utf8).contains("Pricing"))
        #expect(store.listRecords() == [created.record])
        #expect(store.record(matching: "a1b2c3d4") == created.record)
        #expect(store.resolve(identifier: created.path)?.kind == .react)
    }

    @Test func malformedIndexLineDoesNotHideValidArtifacts() throws {
        let root = temporaryRoot(named: "artifact-malformed-index")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = ArtifactStore(rootPath: root)
        let created = try store.createNew(
            title: "Healthy",
            kind: .html,
            origin: ArtifactOrigin(cwd: nil, repoRoot: nil),
            source: "<p>healthy</p>",
            now: fixedDate,
            shortID: "healthy1"
        )
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: store.indexPath))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))

        #expect(store.listRecords() == [created.record])
    }

    @Test func runtimeStorageSeparatesPersonalAndSharedValues() throws {
        let root = temporaryRoot(named: "artifact-runtime-storage")
        defer { try? FileManager.default.removeItem(atPath: root) }

        try ArtifactRuntimeStorage.set(key: "theme", value: "dark", rootPath: root)
        try ArtifactRuntimeStorage.set(key: "theme", value: "light", shared: true, rootPath: root)
        try ArtifactRuntimeStorage.set(key: "entry:2", value: 2, rootPath: root)

        #expect(try ArtifactRuntimeStorage.get(key: "theme", rootPath: root) as? String == "dark")
        #expect(try ArtifactRuntimeStorage.get(key: "theme", shared: true, rootPath: root) as? String == "light")
        #expect(try ArtifactRuntimeStorage.list(prefix: "entry:", rootPath: root) == ["entry:2"])

        try ArtifactRuntimeStorage.delete(key: "theme", rootPath: root)
        #expect(try ArtifactRuntimeStorage.get(key: "theme", shared: true, rootPath: root) as? String == "light")
        #expect(try ArtifactRuntimeStorage.list(rootPath: root) == ["entry:2"])
    }

    @Test func revisionStoreSnapshotsOnlyChangedContent() throws {
        let root = temporaryRoot(named: "artifact-revisions")
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let sourcePath = (root as NSString).appendingPathComponent("artifact.tsx")
        try "v1".write(toFile: sourcePath, atomically: true, encoding: .utf8)

        let first = try ArtifactVersionStore.snapshotIfChanged(
            filePath: sourcePath,
            rootPath: root,
            lastDigest: nil,
            now: fixedDate
        )
        let unchanged = try ArtifactVersionStore.snapshotIfChanged(
            filePath: sourcePath,
            rootPath: root,
            lastDigest: first.digest,
            now: fixedDate.addingTimeInterval(1)
        )
        try "v2".write(toFile: sourcePath, atomically: true, encoding: .utf8)
        let second = try ArtifactVersionStore.snapshotIfChanged(
            filePath: sourcePath,
            rootPath: root,
            lastDigest: first.digest,
            now: fixedDate.addingTimeInterval(2)
        )

        #expect(first.record != nil)
        #expect(unchanged.record == nil)
        #expect(second.record != nil)
        #expect(second.digest != first.digest)
        if let relativePath = second.record?.revisionFile {
            let revisionPath = (root as NSString).appendingPathComponent(relativePath)
            #expect(try String(contentsOfFile: revisionPath, encoding: .utf8) == "v2")
        }
    }

    @Test func externalPreviewEscapesEmbeddedClosingScript() throws {
        let shell = """
        <html><body><script>
        function reactDocument() { return `<html><body></body></html>`; }
        window.__cmuxRenderArtifact = function(payload) {};
        </script></body></html>
        """
        let source = #"export default function Artifact() { return <div>{\"</script><p>escaped</p>\"}</div>; }"#

        let document = try ArtifactExternalPreview.makePreviewDocument(
            shellHTML: shell,
            source: source,
            kind: .react,
            filePath: "/tmp/showcase.tsx"
        )

        #expect(document.contains("window.__cmuxRenderArtifact(payload)"))
        #expect(document.contains(#"\u003c\/script>\u003cp>escaped\u003c\/p>"#))
        #expect(!document.contains("</script><p>escaped</p>"))
    }

    private func temporaryRoot(named name: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
            .path
    }
}
