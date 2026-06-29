import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("ArtifactStore", .serialized)
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

    @Test func kindDefaultExtensions() {
        #expect(ArtifactKind.react.fileExtension == "tsx")
        #expect(ArtifactKind.html.fileExtension == "html")
        #expect(ArtifactKind.svg.fileExtension == "svg")
        #expect(ArtifactKind.mermaid.fileExtension == "mermaid")
        #expect(ArtifactKind.code.fileExtension == "txt")
        #expect(ArtifactKind.file.fileExtension == "bin")
    }

    @Test func kindClassifiesByExtension() {
        #expect(ArtifactKind.kind(forFileExtension: "jsx") == .react)
        #expect(ArtifactKind.kind(forFileExtension: "TSX") == .react)
        #expect(ArtifactKind.kind(forFileExtension: "js") == .react)
        #expect(ArtifactKind.kind(forFileExtension: "html") == .html)
        #expect(ArtifactKind.kind(forFileExtension: "htm") == .html)
        #expect(ArtifactKind.kind(forFileExtension: "svg") == .svg)
        #expect(ArtifactKind.kind(forFileExtension: "mermaid") == .mermaid)
        #expect(ArtifactKind.kind(forFileExtension: "mmd") == .mermaid)
        #expect(ArtifactKind.kind(forFileExtension: "swift") == .code)
        #expect(ArtifactKind.kind(forFileExtension: "py") == .code)
        #expect(ArtifactKind.kind(forFileExtension: "txt") == .code)
        #expect(ArtifactKind.kind(forFileExtension: "pdf") == .file)
        #expect(ArtifactKind.kind(forFileExtension: "docx") == .file)
        #expect(ArtifactKind.kind(forFileExtension: "xlsx") == .file)
        #expect(ArtifactKind.kind(forFileExtension: "pptx") == .file)
    }

    @Test func kindReturnsNilForPanelRoutedExtensions() {
        // .md routes to the existing MarkdownPanel, not the artifact renderer.
        #expect(ArtifactKind.kind(forFileExtension: "md") == nil)
        #expect(ArtifactKind.kind(forFileExtension: "markdown") == nil)
    }

    @Test func kindRenderStrategiesMatchCompatibilityMatrix() {
        #expect(ArtifactKind.react.rendersInWebView)
        #expect(ArtifactKind.html.rendersInWebView)
        #expect(ArtifactKind.svg.rendersInWebView)
        #expect(ArtifactKind.mermaid.rendersInWebView)
        #expect(ArtifactKind.code.rendersInWebView)
        #expect(!ArtifactKind.file.rendersInWebView)
        #expect(!ArtifactKind.file.requiresTextSource)
    }

    @Test func bundledLiveEventsSampleIsAvailable() throws {
        let sample = try #require(ArtifactSamples.sample(named: "live-events"))

        #expect(sample.title == "Live Events Cockpit")
        #expect(sample.kind == .react)
        #expect(ArtifactSamples.source(for: sample)?.contains("Live event cockpit") == true)
        #expect(ArtifactSamples.source(for: sample)?.contains("Event stream guide") == true)
        #expect(ArtifactSamples.source(for: sample)?.contains("Conductor and skills") == true)
        #expect(ArtifactSamples.source(for: sample)?.contains("Artifact bridge API") == true)
        #expect(ArtifactSamples.source(for: sample)?.contains("window.cmux") == true)
        #expect(ArtifactSamples.source(for: sample)?.contains("V3 native workbench TODO") == true)
    }

    @MainActor
    @Test func cmuxBridgeReportsReadOnlyCapabilities() throws {
        let bridge = ArtifactRuntimeCmuxBridge()

        let response = bridge.handle(request: [
            "requestId": "capabilities-1",
            "op": "call",
            "payload": [
                "method": "capabilities",
                "params": [:]
            ]
        ])

        #expect(response["requestId"] as? String == "capabilities-1")
        #expect(response["ok"] as? Bool == true)
        let value = try #require(response["value"] as? [String: Any])
        #expect(value["read_only"] as? Bool == true)
        let methods = try #require(value["methods"] as? [String])
        #expect(methods.contains("system.snapshot"))
        #expect(methods.contains("events.snapshot"))
        #expect(methods.contains("surface.read"))
        #expect(methods.contains("readSurface"))
    }

    @MainActor
    @Test func cmuxBridgeSurfaceReadReportsMissingSurface() throws {
        let bridge = ArtifactRuntimeCmuxBridge()

        let response = bridge.handle(request: [
            "requestId": "surface-read-1",
            "op": "call",
            "payload": [
                "method": "surface.read",
                "params": [
                    "surfaceId": "missing-surface"
                ]
            ]
        ])

        #expect(response["requestId"] as? String == "surface-read-1")
        #expect(response["ok"] as? Bool == true)
        let value = try #require(response["value"] as? [String: Any])
        #expect(value["ok"] as? Bool == false)
        #expect(value["code"] as? String == "not_found")
    }

    @MainActor
    @Test func cmuxBridgeReturnsRetainedEventSnapshot() throws {
        #if DEBUG
        CmuxEventBus.shared.resetForTesting()
        #endif
        CmuxEventBus.shared.publish(
            name: "artifact.test",
            category: "artifact",
            source: "test",
            workspaceId: "workspace-1",
            payload: ["kind": "bridge"]
        )
        let bridge = ArtifactRuntimeCmuxBridge()

        let response = bridge.handle(request: [
            "requestId": "events-1",
            "op": "call",
            "payload": [
                "method": "events.snapshot",
                "params": [
                    "scope": "all",
                    "limit": 10
                ]
            ]
        ])

        #expect(response["requestId"] as? String == "events-1")
        #expect(response["ok"] as? Bool == true)
        let value = try #require(response["value"] as? [String: Any])
        let events = try #require(value["events"] as? [[String: Any]])
        let event = try #require(events.first)
        #expect(event["name"] as? String == "artifact.test")
        #expect(event["category"] as? String == "artifact")
    }

    @MainActor
    @Test func cmuxBridgeDispatchesLiveSubscribedEvents() async throws {
        #if DEBUG
        CmuxEventBus.shared.resetForTesting()
        #endif
        let bridge = ArtifactRuntimeCmuxBridge()
        #if DEBUG
        var delivered: [[String: Any]] = []
        bridge.dispatchSinkForTesting = { _, event in
            delivered.append(event)
        }
        #endif

        let response = bridge.handle(request: [
            "requestId": "subscribe-1",
            "op": "subscribe",
            "payload": [
                "options": [
                    "scope": "all",
                    "replayLimit": 0
                ]
            ]
        ])

        #expect(response["requestId"] as? String == "subscribe-1")
        #expect(response["ok"] as? Bool == true)
        let value = try #require(response["value"] as? [String: Any])
        let subscriptionId = try #require(value["subscription_id"] as? String)

        CmuxEventBus.shared.publish(
            name: "artifact.live",
            category: "artifact",
            source: "test",
            workspaceId: "workspace-1",
            payload: ["kind": "bridge-live"]
        )

        #if DEBUG
        let deadline = Date().addingTimeInterval(2)
        while delivered.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let event = try #require(delivered.first)
        #expect(event["name"] as? String == "artifact.live")
        #expect(event["category"] as? String == "artifact")
        #endif

        let unsubscribe = bridge.handle(request: [
            "requestId": "unsubscribe-1",
            "op": "unsubscribe",
            "payload": [
                "subscriptionId": subscriptionId
            ]
        ])
        #expect(unsubscribe["ok"] as? Bool == true)
    }

    @Test func externalPreviewDocumentBootsArtifactRuntime() throws {
        let shell = """
        <!doctype html>
        <html>
        <body>
        <div id="surface"></div>
        <script>
        function reactDocument() {
          return `<html><body><script type="module"><\\/script></body></html>`;
        }
        window.__cmuxRenderArtifact = function(payload) {
          window.renderedArtifactPayload = payload;
        };
        </script>
        </body>
        </html>
        """
        let source = #"export default function Artifact() { return <div>{"</script><p>escaped</p>"}</div>; }"#

        let document = try ArtifactExternalPreview.makePreviewDocument(
            shellHTML: shell,
            source: source,
            kind: .react,
            filePath: "/tmp/showcase.tsx"
        )

        #expect(document.contains("window.__cmuxRenderArtifact(payload)"))
        let innerBodyRange = try #require(document.range(of: "</body></html>`;"))
        let bootScriptRange = try #require(document.range(of: "window.__cmuxRenderArtifact(payload)"))
        #expect(innerBodyRange.lowerBound < bootScriptRange.lowerBound)
        #expect(document.contains(#""kind":"react""#))
        #expect(document.contains(#""filePath":"\/tmp\/showcase.tsx""#))
        #expect(document.contains(#"\u003c\/script>\u003cp>escaped\u003c\/p>"#))
        #expect(!document.contains("</script><p>escaped</p>"))
    }

    @Test func saveToDownloadsUsesArtifactFilenameWithoutOverwriting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = directory.appendingPathComponent("showcase.tsx", isDirectory: false)
        try "existing".write(to: existing, atomically: true, encoding: .utf8)

        let saved = try ArtifactDownload.write(
            source: "export default function Artifact() { return null; }",
            originalFilePath: "/tmp/showcase.tsx",
            destinationDirectory: directory
        )

        #expect(saved.lastPathComponent == "showcase 2.tsx")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "existing")
        #expect(try String(contentsOf: saved, encoding: .utf8) == "export default function Artifact() { return null; }")
    }

    @Test func copyToDownloadsPreservesBinaryArtifactBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-download-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-source-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: sourceDirectory)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceURL = sourceDirectory.appendingPathComponent("report.pdf", isDirectory: false)
        let bytes = Data([0x25, 0x50, 0x44, 0x46, 0x00, 0xff, 0x10])
        try bytes.write(to: sourceURL)

        let saved = try ArtifactDownload.copy(
            originalFilePath: sourceURL.path,
            destinationDirectory: directory
        )

        #expect(saved.lastPathComponent == "report.pdf")
        #expect(try Data(contentsOf: saved) == bytes)
    }

    @Test func runtimeStoragePersistsListsAndDeletesValues() throws {
        let tempRoot = NSTemporaryDirectory() + "artifact-storage-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }

        try ArtifactRuntimeStorage.set(
            key: "entries:settings",
            value: ["theme": "dark", "count": 2],
            rootPath: tempRoot
        )
        try ArtifactRuntimeStorage.set(
            key: "other",
            value: "ignored",
            rootPath: tempRoot
        )
        try ArtifactRuntimeStorage.set(
            key: "shared-flag",
            value: true,
            shared: true,
            rootPath: tempRoot
        )

        let value = try ArtifactRuntimeStorage.get(key: "entries:settings", rootPath: tempRoot) as? [String: Any]
        #expect(value?["theme"] as? String == "dark")
        #expect(value?["count"] as? Int == 2)
        let entry = try ArtifactRuntimeStorage.getEntry(key: "entries:settings", rootPath: tempRoot)
        #expect(entry?["key"] as? String == "entries:settings")
        #expect(entry?["shared"] as? Bool == false)
        #expect(try ArtifactRuntimeStorage.list(prefix: "entries:", rootPath: tempRoot) == ["entries:settings"])
        #expect(try ArtifactRuntimeStorage.list(shared: true, rootPath: tempRoot) == ["shared-flag"])

        try ArtifactRuntimeStorage.delete(key: "entries:settings", rootPath: tempRoot)
        #expect(try ArtifactRuntimeStorage.list(prefix: "entries:", rootPath: tempRoot).isEmpty)
    }

    @Test func runtimeStorageBridgeReturnsNullForMissingKeys() {
        let tempRoot = NSTemporaryDirectory() + "artifact-storage-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }

        let response = ArtifactRuntimeStorage.handle(
            message: [
                "requestId": "1",
                "op": "get",
                "key": "missing"
            ],
            rootPath: tempRoot
        )

        #expect(response["requestId"] as? String == "1")
        #expect(response["ok"] as? Bool == true)
        #expect(response["value"] is NSNull)
    }

    @Test func runtimeStorageBridgeListsKeysByPrefix() throws {
        let tempRoot = NSTemporaryDirectory() + "artifact-storage-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }

        try ArtifactRuntimeStorage.set(key: "entries:1", value: "one", rootPath: tempRoot)
        try ArtifactRuntimeStorage.set(key: "entries:2", value: "two", rootPath: tempRoot)
        try ArtifactRuntimeStorage.set(key: "other:1", value: "ignored", rootPath: tempRoot)

        let response = ArtifactRuntimeStorage.handle(
            message: [
                "requestId": "2",
                "op": "list",
                "prefix": "entries:"
            ],
            rootPath: tempRoot
        )

        #expect(response["ok"] as? Bool == true)
        let value = response["value"] as? [String: Any]
        #expect(value?["keys"] as? [String] == ["entries:1", "entries:2"])
        #expect(value?["shared"] as? Bool == false)
    }

    @Test func versionStoreSnapshotsChangedContentOnly() throws {
        let tempRoot = NSTemporaryDirectory() + "artifact-versions-\(UUID().uuidString)"
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-version-source-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(atPath: tempRoot)
            try? FileManager.default.removeItem(at: sourceDirectory)
        }

        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceURL = sourceDirectory.appendingPathComponent("example.js", isDirectory: false)
        try "const value = 1;\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        let first = try ArtifactVersionStore.snapshotIfChanged(
            filePath: sourceURL.path,
            rootPath: tempRoot,
            lastDigest: nil,
            now: fixedDate
        )
        let duplicate = try ArtifactVersionStore.snapshotIfChanged(
            filePath: sourceURL.path,
            rootPath: tempRoot,
            lastDigest: first.digest,
            now: fixedDate.addingTimeInterval(1)
        )
        try "const value = 2;\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        let second = try ArtifactVersionStore.snapshotIfChanged(
            filePath: sourceURL.path,
            rootPath: tempRoot,
            lastDigest: duplicate.digest,
            now: fixedDate.addingTimeInterval(2)
        )

        #expect(first.record?.revisionFile.hasPrefix("versions/") == true)
        #expect(duplicate.record == nil)
        #expect(second.record != nil)
        #expect(FileManager.default.fileExists(atPath: (tempRoot as NSString).appendingPathComponent(first.record!.revisionFile)))
        #expect(FileManager.default.fileExists(atPath: (tempRoot as NSString).appendingPathComponent(second.record!.revisionFile)))

        let index = try String(contentsOfFile: ArtifactVersionStore.indexPath(rootPath: tempRoot), encoding: .utf8)
        #expect(index.split(separator: "\n").count == 2)
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

    @Test func listRecordsForRecallIsNewestFirstAndHonorsRepoAndLimit() throws {
        let tempRoot = NSTemporaryDirectory() + "artifact-store-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let store = ArtifactStore(rootPath: tempRoot)

        let first = ArtifactStore.makeRecord(
            id: "11111111",
            createdAt: fixedDate,
            title: "First",
            kind: .react,
            origin: ArtifactOrigin(repoRoot: "/repo/a")
        )
        let second = ArtifactStore.makeRecord(
            id: "22222222",
            createdAt: fixedDate.addingTimeInterval(10),
            title: "Second",
            kind: .html,
            origin: ArtifactOrigin(repoRoot: "/repo/b")
        )
        let third = ArtifactStore.makeRecord(
            id: "33333333",
            createdAt: fixedDate.addingTimeInterval(20),
            title: "Third",
            kind: .react,
            origin: ArtifactOrigin(repoRoot: "/repo/a")
        )
        try store.appendToIndex(first)
        try store.appendToIndex(second)
        try store.appendToIndex(third)

        #expect(store.listRecords().map(\.id) == ["11111111", "22222222", "33333333"])
        #expect(store.listRecords(limit: 2).map(\.id) == ["33333333", "22222222"])
        #expect(store.listRecords(repoRoot: "/repo/a").map(\.id) == ["33333333", "11111111"])
        #expect(store.listRecords(repoRoot: "/repo/a", limit: 1).map(\.id) == ["33333333"])
    }

    @Test func resolveFindsRecordsByIdRelativePathAbsolutePathAndFilename() throws {
        let tempRoot = NSTemporaryDirectory() + "artifact-store-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let store = ArtifactStore(rootPath: tempRoot)

        let record = ArtifactStore.makeRecord(
            id: "cafebabe",
            createdAt: fixedDate,
            title: "Lookup Target",
            kind: .react,
            origin: ArtifactOrigin()
        )
        let absolute = try store.create(scaffold: "export default () => null;", record: record)
        let filename = (record.file as NSString).lastPathComponent

        #expect(store.resolve(identifier: "cafebabe")?.path == absolute)
        #expect(store.resolve(identifier: record.file)?.path == absolute)
        #expect(store.resolve(identifier: absolute)?.record == record)
        #expect(store.resolve(identifier: filename)?.kind == .react)
    }

    @Test func resolveDirectPathInfersKindWithoutIndexRecord() {
        let tempRoot = NSTemporaryDirectory() + "artifact-store-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        let store = ArtifactStore(rootPath: tempRoot)

        let resolved = store.resolve(identifier: "/tmp/direct.html")

        #expect(resolved?.record == nil)
        #expect(resolved?.path == "/tmp/direct.html")
        #expect(resolved?.kind == .html)
    }
}
