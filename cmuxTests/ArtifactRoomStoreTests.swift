import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class ArtifactRoomFailureCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func record(_ error: Error) {
        lock.lock()
        messages.append(error.localizedDescription)
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

@Suite("ArtifactRoomStore")
struct ArtifactRoomStoreTests {
    private func makeTempArtifactPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-room-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("room.html", isDirectory: false).path
    }

    @Test func sidecarPathAppendsRoomSuffix() throws {
        let store = ArtifactRoomStore(artifactFilePath: "/tmp/scratch/room.html")
        #expect(store.roomPath == "/tmp/scratch/room.html.room.jsonl")
    }

    @Test func readReportsMissingSidecar() throws {
        let store = ArtifactRoomStore(artifactFilePath: try makeTempArtifactPath())
        let result = store.read()
        #expect(result.exists == false)
        #expect(result.entries.isEmpty)
        #expect(result.skipped == 0)
    }

    @Test func appendThenReadRoundTripsEntriesInOrder() throws {
        let artifactPath = try makeTempArtifactPath()
        defer { try? FileManager.default.removeItem(atPath: (artifactPath as NSString).deletingLastPathComponent) }
        let store = ArtifactRoomStore(artifactFilePath: artifactPath)

        let join = try store.append(entry: [
            "type": "join", "name": "Fable", "model": "claude-fable-5", "role": "agent"
        ])
        try store.append(entry: ["type": "msg", "name": "Fable", "body": "hello room"])

        #expect(join["ts"] as? String != nil)

        let result = store.read()
        #expect(result.exists)
        #expect(result.skipped == 0)
        #expect(result.entries.count == 2)
        #expect(result.entries[0]["type"] as? String == "join")
        #expect(result.entries[0]["model"] as? String == "claude-fable-5")
        #expect(result.entries[1]["body"] as? String == "hello room")
    }

    @Test func readAcceptsExternalShellStyleAppends() throws {
        let artifactPath = try makeTempArtifactPath()
        defer { try? FileManager.default.removeItem(atPath: (artifactPath as NSString).deletingLastPathComponent) }
        let store = ArtifactRoomStore(artifactFilePath: artifactPath)
        try store.append(entry: ["type": "join", "name": "Operator", "role": "human"])

        // Simulate an agent appending with `printf ... >> room.jsonl`.
        let externalLine = "{\"type\":\"msg\",\"name\":\"Codex\",\"body\":\"joining via shell\"}\n"
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: store.roomPath))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(externalLine.utf8))
        try handle.close()

        let result = store.read()
        #expect(result.entries.count == 2)
        #expect(result.entries[1]["name"] as? String == "Codex")
    }

    @Test func readSkipsMalformedLinesWithoutDroppingTheRest() throws {
        let artifactPath = try makeTempArtifactPath()
        defer { try? FileManager.default.removeItem(atPath: (artifactPath as NSString).deletingLastPathComponent) }
        let store = ArtifactRoomStore(artifactFilePath: artifactPath)
        try store.append(entry: ["type": "msg", "name": "Fable", "body": "first"])

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: store.roomPath))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("this is not json\n".utf8))
        try handle.close()
        try store.append(entry: ["type": "msg", "name": "Fable", "body": "second"])

        let result = store.read()
        #expect(result.skipped == 1)
        #expect(result.entries.count == 2)
        #expect(result.entries[1]["body"] as? String == "second")
    }

    @Test func appendRejectsMissingName() throws {
        let store = ArtifactRoomStore(artifactFilePath: try makeTempArtifactPath())
        #expect(throws: ArtifactRoomStore.RoomError.missingName) {
            try store.append(entry: ["type": "msg", "body": "anonymous"])
        }
    }

    @Test func appendRejectsMessageWithoutBody() throws {
        let store = ArtifactRoomStore(artifactFilePath: try makeTempArtifactPath())
        #expect(throws: ArtifactRoomStore.RoomError.missingBody) {
            try store.append(entry: ["type": "msg", "name": "Fable"])
        }
    }

    @Test func appendAllowsJoinWithoutBody() throws {
        let artifactPath = try makeTempArtifactPath()
        defer { try? FileManager.default.removeItem(atPath: (artifactPath as NSString).deletingLastPathComponent) }
        let store = ArtifactRoomStore(artifactFilePath: artifactPath)
        let entry = try store.append(entry: ["type": "join", "name": "Codex"])
        #expect(entry["type"] as? String == "join")
    }

    @Test func appendRejectsUnknownType() throws {
        let store = ArtifactRoomStore(artifactFilePath: try makeTempArtifactPath())
        #expect(throws: ArtifactRoomStore.RoomError.invalidType("shout")) {
            try store.append(entry: ["type": "shout", "name": "Fable", "body": "!"])
        }
    }

    @Test func appendDropsUnknownKeysFromStoredLine() throws {
        let artifactPath = try makeTempArtifactPath()
        defer { try? FileManager.default.removeItem(atPath: (artifactPath as NSString).deletingLastPathComponent) }
        let store = ArtifactRoomStore(artifactFilePath: artifactPath)
        try store.append(entry: [
            "type": "msg", "name": "Fable", "body": "hi",
            "requestId": "should-not-persist", "extra": "nope"
        ])
        let stored = store.read().entries[0]
        #expect(stored["requestId"] == nil)
        #expect(stored["extra"] == nil)
        #expect(stored["body"] as? String == "hi")
    }

    @Test func appendRejectsOversizedEntry() throws {
        let store = ArtifactRoomStore(artifactFilePath: try makeTempArtifactPath())
        let hugeBody = String(repeating: "a", count: ArtifactRoomStore.maxEntryBytes + 1)
        #expect(throws: ArtifactRoomStore.RoomError.entryTooLarge) {
            try store.append(entry: ["type": "msg", "name": "Fable", "body": hugeBody])
        }
    }

    @Test func concurrentAppendsRemainDistinctJSONLines() throws {
        let artifactPath = try makeTempArtifactPath()
        defer { try? FileManager.default.removeItem(atPath: (artifactPath as NSString).deletingLastPathComponent) }
        let store = ArtifactRoomStore(artifactFilePath: artifactPath)
        let failures = ArtifactRoomFailureCollector()
        let appendCount = 200

        DispatchQueue.concurrentPerform(iterations: appendCount) { index in
            do {
                try store.append(entry: [
                    "type": "msg",
                    "name": "Writer-\(index)",
                    "body": "message-\(index)"
                ])
            } catch {
                failures.record(error)
            }
        }

        let result = store.read()
        let bodies = Set(result.entries.compactMap { $0["body"] as? String })
        #expect(failures.snapshot.isEmpty)
        #expect(result.skipped == 0)
        #expect(result.entries.count == appendCount)
        #expect(bodies.count == appendCount)
    }

    @Test func readReturnsOnlyTheBoundedTailOfLargeExternalLogs() throws {
        let artifactPath = try makeTempArtifactPath()
        defer { try? FileManager.default.removeItem(atPath: (artifactPath as NSString).deletingLastPathComponent) }
        let store = ArtifactRoomStore(artifactFilePath: artifactPath)
        let oversizedPrefix = String(repeating: "x", count: ArtifactRoomStore.maxReadBytes + 1)
        var data = Data((oversizedPrefix + "\n").utf8)
        for index in 0..<(ArtifactRoomStore.maxReadEntries + 25) {
            data.append(Data("{\"type\":\"msg\",\"name\":\"External\",\"body\":\"message-\(index)\"}\n".utf8))
        }
        try data.write(to: URL(fileURLWithPath: store.roomPath))

        let result = store.read()

        #expect(result.truncated)
        #expect(result.entries.count == ArtifactRoomStore.maxReadEntries)
        #expect(result.entries.last?["body"] as? String == "message-\(ArtifactRoomStore.maxReadEntries + 24)")
    }
}

@Suite("ArtifactRoomBridge")
struct ArtifactRoomBridgeTests {
    @MainActor
    @Test func bridgeRoomPostThenReadRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-room-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifactPath = directory.appendingPathComponent("room.html", isDirectory: false).path

        let bridge = ArtifactRuntimeCmuxBridge()
        bridge.update(
            panelId: UUID(),
            workspaceId: UUID(),
            filePath: artifactPath,
            webView: nil,
            roomEnabled: true
        )
        defer { bridge.close() }

        let post = bridge.handle(request: [
            "requestId": "room-post-1",
            "op": "call",
            "payload": [
                "method": "room.post",
                "params": ["type": "msg", "name": "Operator", "role": "human", "body": "hello agents"]
            ]
        ])
        #expect(post["ok"] as? Bool == true)
        let postValue = try #require(post["value"] as? [String: Any])
        #expect(postValue["ok"] as? Bool == true)
        #expect((postValue["path"] as? String)?.hasSuffix(".room.jsonl") == true)

        let read = bridge.handle(request: [
            "requestId": "room-read-1",
            "op": "call",
            "payload": ["method": "room.read", "params": [:]]
        ])
        #expect(read["ok"] as? Bool == true)
        let readValue = try #require(read["value"] as? [String: Any])
        #expect(readValue["exists"] as? Bool == true)
        let entries = try #require(readValue["entries"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries[0]["body"] as? String == "hello agents")
    }

    @MainActor
    @Test func bridgeRoomPostReportsValidationFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-room-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifactPath = directory.appendingPathComponent("room.html", isDirectory: false).path

        let bridge = ArtifactRuntimeCmuxBridge()
        bridge.update(
            panelId: UUID(),
            workspaceId: UUID(),
            filePath: artifactPath,
            webView: nil,
            roomEnabled: true
        )
        defer { bridge.close() }

        let post = bridge.handle(request: [
            "requestId": "room-post-invalid",
            "op": "call",
            "payload": [
                "method": "room.post",
                "params": ["type": "msg", "body": "no name"]
            ]
        ])
        #expect(post["ok"] as? Bool == true)
        let value = try #require(post["value"] as? [String: Any])
        #expect(value["ok"] as? Bool == false)
        #expect(value["code"] as? String == "invalid_params")
    }

    @MainActor
    @Test func bridgeRejectsRoomWritesWithoutArtifactOptIn() throws {
        let bridge = ArtifactRuntimeCmuxBridge()
        bridge.update(panelId: UUID(), workspaceId: UUID(), filePath: "/tmp/plain.html", webView: nil)
        defer { bridge.close() }

        let capabilities = bridge.handle(request: [
            "requestId": "capabilities-plain",
            "op": "call",
            "payload": ["method": "capabilities", "params": [:]]
        ])
        let capabilityValue = try #require(capabilities["value"] as? [String: Any])
        #expect(capabilityValue["read_only"] as? Bool == true)
        #expect(!(try #require(capabilityValue["methods"] as? [String])).contains("room.post"))

        let post = bridge.handle(request: [
            "requestId": "room-post-disabled",
            "op": "call",
            "payload": [
                "method": "room.post",
                "params": ["type": "msg", "name": "Operator", "body": "blocked"]
            ]
        ])
        #expect(post["ok"] as? Bool == false)
    }
}
