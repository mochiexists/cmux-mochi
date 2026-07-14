import Darwin
import Foundation

/// Append-only JSONL message log backing a multi-agent scratchpad artifact
/// (the bundled "writers-room" template). The log is a sidecar file next to
/// the artifact source — `<artifact>.room.jsonl` — so agents can post from a
/// shell with a one-line append while the artifact renders the same file
/// through the runtime bridge (`room.read` / `room.post`).
///
/// Entry shape (one JSON object per line):
/// `{"ts": "2026-07-09T21:00:00Z", "type": "msg", "name": "Fable",
///   "model": "claude-fable-5", "role": "agent", "body": "..."}`
/// `type` is `join` (identify on entering the room), `msg` (default), or
/// `note` (out-of-band housekeeping).
struct ArtifactRoomStore: Sendable {
    /// Absolute path of the JSONL room log.
    let roomPath: String

    /// Maximum accepted size for one posted entry, in bytes.
    static let maxEntryBytes = 32 * 1024

    /// Maximum tail size loaded for one read. Older bytes are omitted before
    /// parsing so an externally grown log cannot stall the artifact renderer.
    static let maxReadBytes = 1024 * 1024

    /// Maximum number of parsed entries returned to the artifact.
    static let maxReadEntries = 500

    /// Maximum accepted participant-name length, in characters.
    static let maxNameLength = 64

    /// Entry types the room accepts.
    static let allowedTypes: Set<String> = ["join", "msg", "note"]

    /// Keys copied from a posted entry into the stored line; everything else
    /// is dropped so the log stays a predictable, greppable schema.
    private static let allowedKeys: Set<String> = ["type", "name", "model", "role", "body"]

    /// Sidecar path convention: the artifact source path plus `.room.jsonl`.
    init(artifactFilePath: String) {
        self.roomPath = artifactFilePath + ".room.jsonl"
    }

    /// Parses the room log. Malformed lines are counted and skipped so one bad
    /// append never hides the rest of the conversation.
    func read(
        fileManager: FileManager = .default
    ) -> (entries: [[String: Any]], skipped: Int, exists: Bool, truncated: Bool) {
        guard fileManager.fileExists(atPath: roomPath) else {
            return ([], 0, false, false)
        }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: roomPath)) else {
            return ([], 0, true, false)
        }
        defer { try? handle.close() }

        guard let endOffset = try? handle.seekToEnd() else {
            return ([], 0, true, false)
        }
        let maxBytes = UInt64(Self.maxReadBytes)
        let startOffset = endOffset > maxBytes ? endOffset - maxBytes : 0
        do {
            try handle.seek(toOffset: startOffset)
        } catch {
            return ([], 0, true, startOffset > 0)
        }
        guard var data = try? handle.readToEnd() ?? Data() else {
            return ([], 0, true, startOffset > 0)
        }

        var truncated = startOffset > 0
        if startOffset > 0 {
            guard let firstNewline = data.firstIndex(of: 0x0a) else {
                return ([], 0, true, true)
            }
            data.removeSubrange(data.startIndex...firstNewline)
        }

        var entries: [[String: Any]] = []
        var skipped = 0
        for line in data.split(separator: 0x0a) {
            guard !line.isEmpty else { continue }
            guard line.count <= Self.maxEntryBytes,
                  let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                skipped += 1
                continue
            }
            entries.append(object)
        }
        if entries.count > Self.maxReadEntries {
            entries = Array(entries.suffix(Self.maxReadEntries))
            truncated = true
        }
        return (entries, skipped, true, truncated)
    }

    /// Validates and appends one entry as a JSON line, creating the file when
    /// missing. Returns the normalized entry (with server timestamp) that was
    /// written.
    @discardableResult
    func append(
        entry raw: [String: Any],
        now: Date = Date()
    ) throws -> [String: Any] {
        var entry: [String: Any] = [:]
        for key in Self.allowedKeys {
            if let value = raw[key] as? String, !value.isEmpty {
                entry[key] = value
            }
        }

        let type = (entry["type"] as? String) ?? "msg"
        guard Self.allowedTypes.contains(type) else {
            throw RoomError.invalidType(type)
        }
        entry["type"] = type

        guard let name = entry["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoomError.missingName
        }
        guard name.count <= Self.maxNameLength else {
            throw RoomError.nameTooLong
        }
        if type == "msg" {
            guard let body = entry["body"] as? String,
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RoomError.missingBody
            }
        }
        entry["ts"] = Self.isoTimestamp(now)

        guard JSONSerialization.isValidJSONObject(entry) else {
            throw RoomError.invalidEntry
        }
        var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= Self.maxEntryBytes else {
            throw RoomError.entryTooLarge
        }
        data.append(0x0a)

        try appendAtomically(data)
        return entry
    }

    /// Uses an advisory cross-process lock and `O_APPEND` so bridge writes and
    /// shell/agent writers cannot race the file offset or overwrite creation.
    private func appendAtomically(_ data: Data) throws {
        let descriptor = Darwin.open(
            roomPath,
            O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }

        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard written > 0 else {
                    throw POSIXError(.EIO)
                }
                offset += written
            }
        }
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    enum RoomError: LocalizedError, Equatable {
        case missingName
        case nameTooLong
        case missingBody
        case invalidType(String)
        case invalidEntry
        case entryTooLarge

        var errorDescription: String? {
            switch self {
            case .missingName: return "room entries require a non-empty name"
            case .nameTooLong: return "room entry name exceeds \(ArtifactRoomStore.maxNameLength) characters"
            case .missingBody: return "room messages require a non-empty body"
            case .invalidType(let type): return "unsupported room entry type '\(type)'"
            case .invalidEntry: return "room entry must be JSON-serializable strings"
            case .entryTooLarge: return "room entry exceeds \(ArtifactRoomStore.maxEntryBytes) bytes"
            }
        }
    }
}
