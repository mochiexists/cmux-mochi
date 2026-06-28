import Foundation

/// What an artifact renders as. Phase 1 ships `.react`; `.swiftui` is reserved
/// for the iOS-preview spread (see `plans/feat-artifacts/PLAN.md`).
enum ArtifactKind: String, Codable, Sendable, CaseIterable {
    case react
    case swiftui

    /// File extension used for the artifact source file on disk.
    var fileExtension: String {
        switch self {
        case .react: return "tsx"
        case .swiftui: return "swift"
        }
    }
}

/// Where an artifact was created from. Captured once at creation time so the
/// global, flat store keeps the "which project / pane made this" signal without
/// scattering a `.cmux/artifacts/` folder into every working directory.
struct ArtifactOrigin: Codable, Equatable, Sendable {
    var cwd: String?
    var repoRoot: String?
    var workspaceId: String?
    var surfaceId: String?

    init(cwd: String? = nil, repoRoot: String? = nil, workspaceId: String? = nil, surfaceId: String? = nil) {
        self.cwd = cwd
        self.repoRoot = repoRoot
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
    }
}

/// One line in `index.jsonl` — the provenance record for a stored artifact.
struct ArtifactRecord: Codable, Equatable, Sendable {
    var id: String
    /// ISO-8601 UTC timestamp, e.g. `2026-06-28T14:30:22Z`.
    var createdAt: String
    var title: String
    /// Path to the artifact source file, relative to the store root.
    var file: String
    var kind: ArtifactKind
    var origin: ArtifactOrigin
}

/// Global, flat artifact store at `~/.config/cmux/artifacts/`.
///
/// Mirrors how Codex/Claude keep session history globally: date-bucketed source
/// files plus an append-only `index.jsonl` that is the source of truth for
/// recall. Every artifact records the cwd / repo / workspace / surface it was
/// created from (``ArtifactOrigin``) instead of living next to that directory.
/// See `plans/feat-artifacts/PLAN.md`.
struct ArtifactStore {
    /// Absolute path to the store root.
    let rootPath: String

    init(rootPath: String = ArtifactStore.defaultRootPath()) {
        self.rootPath = rootPath
    }

    /// `~/.config/cmux/artifacts`, overridable via the `artifacts.directory`
    /// default (UserDefaults / `cmux.json`). A tilde in the override is expanded.
    static func defaultRootPath(defaults: UserDefaults = .standard) -> String {
        if let override = defaults.string(forKey: "artifacts.directory") {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return (trimmed as NSString).expandingTildeInPath
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/cmux/artifacts")
    }

    /// Absolute path to the append-only provenance index.
    var indexPath: String {
        (rootPath as NSString).appendingPathComponent("index.jsonl")
    }

    // MARK: - Pure helpers (unit-tested)

    /// Normalizes a free-form title into a filesystem-safe slug: lowercased,
    /// non-alphanumeric runs collapsed to single hyphens, trimmed, length-capped.
    /// Falls back to `"artifact"` when nothing usable remains.
    static func slugify(_ raw: String, maxLength: Int = 40) -> String {
        var slug = ""
        var lastWasHyphen = false
        for scalar in raw.lowercased().unicodeScalars {
            if scalar.properties.isAlphabetic || ("0"..."9").contains(Character(scalar)) {
                slug.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                slug.append("-")
                lastWasHyphen = true
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > maxLength {
            slug = String(slug.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        return slug.isEmpty ? "artifact" : slug
    }

    /// Relative path of an artifact source file within the store:
    /// `yyyy/MM/dd/yyyyMMdd-HHmmss-<slug>-<shortID>.<ext>` (UTC).
    static func relativePath(
        createdAt: Date,
        slug: String,
        shortID: String,
        fileExtension: String
    ) -> String {
        let bucket = bucketFormatter.string(from: createdAt)
        let stamp = stampFormatter.string(from: createdAt)
        return "\(bucket)/\(stamp)-\(slug)-\(shortID).\(fileExtension)"
    }

    /// Builds a provenance record for an artifact without touching disk.
    static func makeRecord(
        id: String,
        createdAt: Date,
        title: String,
        kind: ArtifactKind,
        origin: ArtifactOrigin
    ) -> ArtifactRecord {
        let slug = slugify(title)
        let relative = relativePath(
            createdAt: createdAt,
            slug: slug,
            shortID: id,
            fileExtension: kind.fileExtension
        )
        return ArtifactRecord(
            id: id,
            createdAt: isoFormatter.string(from: createdAt),
            title: title,
            file: relative,
            kind: kind,
            origin: origin
        )
    }

    // MARK: - Disk I/O

    /// Absolute path on disk for a record's source file.
    func absolutePath(for record: ArtifactRecord) -> String {
        (rootPath as NSString).appendingPathComponent(record.file)
    }

    /// Writes `scaffold` to the record's file (creating intermediate
    /// directories) and appends the record to `index.jsonl`. Returns the
    /// absolute path of the written source file.
    @discardableResult
    func create(scaffold: String, record: ArtifactRecord) throws -> String {
        let absolute = absolutePath(for: record)
        let directory = (absolute as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        try scaffold.write(toFile: absolute, atomically: true, encoding: .utf8)
        try appendToIndex(record)
        return absolute
    }

    /// Appends one record as a JSON line to `index.jsonl`.
    func appendToIndex(_ record: ArtifactRecord) throws {
        try FileManager.default.createDirectory(
            atPath: rootPath,
            withIntermediateDirectories: true
        )
        var line = try String(data: Self.indexEncoder.encode(record), encoding: .utf8) ?? "{}"
        line += "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: indexPath) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: URL(fileURLWithPath: indexPath))
        }
    }

    /// Reads all records from `index.jsonl`, newest last. Malformed lines are
    /// skipped so one bad entry never breaks recall.
    func listRecords() -> [ArtifactRecord] {
        guard let contents = try? String(contentsOfFile: indexPath, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        return contents.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
            return try? decoder.decode(ArtifactRecord.self, from: data)
        }
    }

    // MARK: - Origin resolution

    /// Resolves the git toplevel for `directory`, or `nil` when not in a repo.
    static func gitRepoRoot(for directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--show-toplevel"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let root = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (root?.isEmpty == false) ? root : nil
        } catch {
            return nil
        }
    }

    /// Builds an ``ArtifactOrigin`` from a triggering pane's cwd, deriving the
    /// repo root via git when available.
    static func resolveOrigin(
        cwd: String?,
        workspaceId: String?,
        surfaceId: String?
    ) -> ArtifactOrigin {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCwd = (trimmedCwd?.isEmpty == false) ? trimmedCwd : nil
        let repoRoot = normalizedCwd.flatMap { gitRepoRoot(for: $0) }
        return ArtifactOrigin(
            cwd: normalizedCwd,
            repoRoot: repoRoot,
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )
    }

    // MARK: - Formatters

    private static let bucketFormatter = makeFormatter("yyyy/MM/dd")
    private static let stampFormatter = makeFormatter("yyyyMMdd-HHmmss")

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let indexEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}
