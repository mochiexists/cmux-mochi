import Foundation
import CryptoKit

/// What an artifact renders as. React/HTML/SVG/Mermaid/code are handled by the
/// artifact web shell. Binary document outputs stay in the artifact surface but
/// are treated as files to open or save, not source to compile.
enum ArtifactKind: String, Codable, Sendable, CaseIterable {
    case react
    case html
    case svg
    case mermaid
    case code
    case file
    case swiftui

    /// Default extension for a NEW artifact source file of this kind. React new
    /// artifacts default to `tsx` (repo TypeScript preference); the classifier
    /// below still accepts `jsx`/`js`/`ts` so claude.ai-authored `.jsx` opens.
    var fileExtension: String {
        switch self {
        case .react: return "tsx"
        case .html: return "html"
        case .svg: return "svg"
        case .mermaid: return "mermaid"
        case .code: return "txt"
        case .file: return "bin"
        case .swiftui: return "swift"
        }
    }

    var displayName: String {
        switch self {
        case .react: return "React"
        case .html: return "HTML"
        case .svg: return "SVG"
        case .mermaid: return "Mermaid"
        case .code: return "Code"
        case .file: return "File"
        case .swiftui: return "SwiftUI"
        }
    }

    var rendersInWebView: Bool {
        switch self {
        case .react, .html, .svg, .mermaid, .code:
            return true
        case .file, .swiftui:
            return false
        }
    }

    var requiresTextSource: Bool {
        switch self {
        case .react, .html, .svg, .mermaid, .code, .swiftui:
            return true
        case .file:
            return false
        }
    }

    var opensAsRenderedBrowserPreview: Bool {
        rendersInWebView
    }

    /// Classifies an existing artifact source file by extension, or `nil` for
    /// extensions that route to other cmux panels rather than the artifact
    /// renderer (`.md` routes to MarkdownPanel).
    static func kind(forFileExtension rawExtension: String) -> ArtifactKind? {
        switch rawExtension.lowercased() {
        case "jsx", "tsx", "js", "ts": return .react
        case "html", "htm": return .html
        case "svg": return .svg
        case "mmd", "mermaid": return .mermaid
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key":
            return .file
        case "txt", "text", "log", "json", "jsonl", "xml", "yaml", "yml", "toml", "csv", "tsv",
             "py", "rb", "go", "rs", "swift", "kt", "java", "c", "h", "m", "mm", "cpp", "cc",
             "cxx", "hpp", "cs", "php", "sh", "bash", "zsh", "fish", "sql", "css", "scss",
             "sass", "less", "vue", "svelte", "astro", "mdx", "graphql", "gql", "ini", "env",
             "dockerfile", "makefile":
            return .code
        default: return nil
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

    // MARK: - Create

    /// Scaffolds a brand-new artifact: allocates a provenance record, writes the
    /// starter source (``ArtifactScaffold``), and appends `index.jsonl`. Returns
    /// the record and the absolute path of the written file.
    /// - Parameter source: explicit starter content (e.g. a bundled sample).
    ///   When `nil`, the kind's ``ArtifactScaffold`` default is used.
    @discardableResult
    func createNew(
        title: String,
        kind: ArtifactKind,
        origin: ArtifactOrigin,
        source: String? = nil,
        now: Date = Date(),
        shortID: String = String(UUID().uuidString.prefix(8)).lowercased()
    ) throws -> (record: ArtifactRecord, path: String) {
        let record = Self.makeRecord(
            id: shortID,
            createdAt: now,
            title: title,
            kind: kind,
            origin: origin
        )
        let scaffold = source ?? ArtifactScaffold.source(for: kind, title: title)
        let path = try create(scaffold: scaffold, record: record)
        return (record, path)
    }

    // MARK: - Disk I/O

    /// Absolute path on disk for a record's source file.
    func absolutePath(for record: ArtifactRecord) -> String {
        (rootPath as NSString).appendingPathComponent(record.file)
    }

    /// Absolute path on disk for a store-relative artifact source path.
    func absolutePath(forRelativePath relativePath: String) -> String {
        (rootPath as NSString).appendingPathComponent(relativePath)
    }

    /// Returns index records newest first, optionally filtered by git repo root.
    func listRecords(repoRoot: String? = nil, limit: Int? = nil) -> [ArtifactRecord] {
        let normalizedRepo = repoRoot.map(Self.normalizedPath)
        let records = listRecords().reversed().filter { record in
            guard let normalizedRepo else { return true }
            guard let recordRepo = record.origin.repoRoot else { return false }
            return Self.normalizedPath(recordRepo) == normalizedRepo
        }
        if let limit, limit >= 0 {
            return Array(records.prefix(limit))
        }
        return records
    }

    /// Finds an artifact by short id, store-relative path, absolute path, or
    /// filename. The newest matching record wins for filename lookups.
    func record(matching identifier: String) -> ArtifactRecord? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let normalizedInput = Self.normalizedPath(expanded)
        let inputFilename = (trimmed as NSString).lastPathComponent

        return listRecords(repoRoot: nil, limit: nil).first { record in
            if record.id == trimmed { return true }
            if record.file == trimmed { return true }
            if (record.file as NSString).lastPathComponent == inputFilename { return true }
            return Self.normalizedPath(absolutePath(for: record)) == normalizedInput
        }
    }

    /// Resolves a user-supplied artifact id/path to a file path, record, and
    /// render kind. Direct paths work even when they are not in the index.
    func resolve(
        identifier: String,
        explicitKind: ArtifactKind? = nil
    ) -> (record: ArtifactRecord?, path: String, kind: ArtifactKind)? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let record = record(matching: trimmed) {
            let path = absolutePath(for: record)
            return (record, path, explicitKind ?? record.kind)
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let absolute = (expanded as NSString).isAbsolutePath
            ? expanded
            : absolutePath(forRelativePath: expanded)
        let ext = (absolute as NSString).pathExtension
        guard let kind = explicitKind ?? ArtifactKind.kind(forFileExtension: ext) else {
            return nil
        }
        return (nil, absolute, kind)
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

    static func normalizedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        return (standardized as NSString).resolvingSymlinksInPath
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

struct ArtifactRevisionRecord: Codable, Equatable, Sendable {
    var id: String
    var createdAt: String
    var sourceFile: String
    var revisionFile: String
    var byteCount: Int
    var sha256: String
}

enum ArtifactVersionStore {
    static let maxSnapshotBytes = 25 * 1024 * 1024

    static func indexPath(rootPath: String = ArtifactStore.defaultRootPath()) -> String {
        (versionsRootPath(rootPath: rootPath) as NSString).appendingPathComponent("index.jsonl")
    }

    static func versionsRootPath(rootPath: String = ArtifactStore.defaultRootPath()) -> String {
        (rootPath as NSString).appendingPathComponent("versions")
    }

    static func snapshotIfChanged(
        filePath: String,
        rootPath: String = ArtifactStore.defaultRootPath(),
        lastDigest: String?,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> (digest: String, record: ArtifactRevisionRecord?) {
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let digest = sha256Hex(data)
        guard digest != lastDigest else {
            return (digest, nil)
        }
        guard data.count <= maxSnapshotBytes else {
            return (digest, nil)
        }

        let key = artifactKey(for: filePath)
        let ext = (filePath as NSString).pathExtension
        let stem = timestampForFilename(now)
        let filename = ext.isEmpty ? "\(stem)-\(String(digest.prefix(12)))" : "\(stem)-\(String(digest.prefix(12))).\(ext)"
        let relativePath = "versions/\(key)/\(filename)"
        let absolutePath = (rootPath as NSString).appendingPathComponent(relativePath)
        let directory = (absolutePath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: absolutePath) {
            try data.write(to: URL(fileURLWithPath: absolutePath), options: [.atomic])
        }

        let record = ArtifactRevisionRecord(
            id: UUID().uuidString.lowercased(),
            createdAt: iso8601UTC(now),
            sourceFile: filePath,
            revisionFile: relativePath,
            byteCount: data.count,
            sha256: digest
        )
        try append(record: record, rootPath: rootPath, fileManager: fileManager)
        return (digest, record)
    }

    static func append(
        record: ArtifactRevisionRecord,
        rootPath: String = ArtifactStore.defaultRootPath(),
        fileManager: FileManager = .default
    ) throws {
        let indexPath = indexPath(rootPath: rootPath)
        let directory = (indexPath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        var data = try encoder.encode(record)
        data.append(0x0a)
        if fileManager.fileExists(atPath: indexPath) {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: indexPath))
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: URL(fileURLWithPath: indexPath), options: [.atomic])
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func artifactKey(for filePath: String) -> String {
        sha256Hex(Data(filePath.utf8))
    }

    private static func timestampForFilename(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func iso8601UTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

enum ArtifactRuntimeStorage {
    static let maxValueBytes = 5 * 1024 * 1024

    static func handle(message body: Any, rootPath: String = ArtifactStore.defaultRootPath()) -> [String: Any] {
        guard let message = body as? [String: Any] else {
            return response(requestId: nil, ok: false, error: "invalid storage message")
        }
        let requestId = message["requestId"] as? String
        guard let op = message["op"] as? String else {
            return response(requestId: requestId, ok: false, error: "missing storage operation")
        }
        let shared = (message["shared"] as? Bool) ?? false
        do {
            switch op {
            case "get":
                let key = try requiredKey(from: message)
                guard let value = try getEntry(key: key, shared: shared, rootPath: rootPath) else {
                    return response(requestId: requestId, ok: true, value: NSNull())
                }
                return response(requestId: requestId, ok: true, value: value)
            case "set":
                let key = try requiredKey(from: message)
                let value = message["value"] ?? NSNull()
                try set(key: key, value: value, shared: shared, rootPath: rootPath)
                return response(requestId: requestId, ok: true, value: true)
            case "delete":
                let key = try requiredKey(from: message)
                try delete(key: key, shared: shared, rootPath: rootPath)
                return response(requestId: requestId, ok: true, value: true)
            case "list":
                let prefix = (message["prefix"] as? String) ?? ""
                let keys = try list(prefix: prefix, shared: shared, rootPath: rootPath)
                return response(requestId: requestId, ok: true, value: ["keys": keys, "shared": shared])
            default:
                return response(requestId: requestId, ok: false, error: "unsupported storage operation")
            }
        } catch {
            return response(requestId: requestId, ok: false, error: error.localizedDescription)
        }
    }

    static func get(key: String, shared: Bool = false, rootPath: String = ArtifactStore.defaultRootPath()) throws -> Any {
        let url = entryURL(key: key, shared: shared, rootPath: rootPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StorageError.keyNotFound
        }
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["value"] ?? NSNull()
    }

    static func getEntry(
        key: String,
        shared: Bool = false,
        rootPath: String = ArtifactStore.defaultRootPath()
    ) throws -> [String: Any]? {
        let url = entryURL(key: key, shared: shared, rootPath: rootPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return [
            "key": object?["key"] as? String ?? key,
            "value": object?["value"] ?? NSNull(),
            "shared": shared
        ]
    }

    static func set(
        key: String,
        value: Any,
        shared: Bool = false,
        rootPath: String = ArtifactStore.defaultRootPath()
    ) throws {
        let directory = storageDirectory(shared: shared, rootPath: rootPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let object: [String: Any] = ["key": key, "value": value]
        guard JSONSerialization.isValidJSONObject(object) else {
            throw StorageError.invalidValue
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= maxValueBytes else {
            throw StorageError.valueTooLarge
        }
        try data.write(to: entryURL(key: key, shared: shared, rootPath: rootPath), options: [.atomic])
    }

    static func delete(key: String, shared: Bool = false, rootPath: String = ArtifactStore.defaultRootPath()) throws {
        let url = entryURL(key: key, shared: shared, rootPath: rootPath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func list(
        prefix: String = "",
        shared: Bool = false,
        rootPath: String = ArtifactStore.defaultRootPath()
    ) throws -> [String] {
        let directory = storageDirectory(shared: shared, rootPath: rootPath)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap { url -> String? in
                guard let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                return object["key"] as? String
            }
            .filter { prefix.isEmpty || $0.hasPrefix(prefix) }
            .sorted()
    }

    static func storageDirectory(shared: Bool, rootPath: String = ArtifactStore.defaultRootPath()) -> URL {
        URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent(shared ? "shared" : "personal", isDirectory: true)
    }

    private static func entryURL(key: String, shared: Bool, rootPath: String) -> URL {
        storageDirectory(shared: shared, rootPath: rootPath)
            .appendingPathComponent("\(ArtifactVersionStore.sha256Hex(Data(key.utf8))).json", isDirectory: false)
    }

    private static func requiredKey(from message: [String: Any]) throws -> String {
        guard let key = message["key"] as? String, !key.isEmpty else {
            throw StorageError.missingKey
        }
        return key
    }

    private static func response(requestId: String?, ok: Bool, value: Any? = nil, error: String? = nil) -> [String: Any] {
        var response: [String: Any] = ["ok": ok]
        response["requestId"] = requestId ?? ""
        if let value {
            response["value"] = value
        }
        if let error {
            response["error"] = error
        }
        return response
    }

    enum StorageError: LocalizedError {
        case missingKey
        case keyNotFound
        case invalidValue
        case valueTooLarge

        var errorDescription: String? {
            switch self {
            case .missingKey: return "storage key is required"
            case .keyNotFound: return "storage key not found"
            case .invalidValue: return "storage value must be JSON-serializable"
            case .valueTooLarge: return "storage value exceeds 5 MB"
            }
        }
    }
}
