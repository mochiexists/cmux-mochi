import CryptoKit
import Foundation

/// Syncs the cmux agent skills that ship inside the app bundle
/// (`Contents/Resources/skills/`) out to the on-disk Codex skills directory
/// (`~/.codex/skills`) so a freshly installed `.app` carries the skills with no
/// manual `skills.sh` step.
///
/// Sync is **hash-guarded** so it never clobbers a user's local edits:
/// - A skill that isn't installed yet is copied (`installed`).
/// - A skill whose on-disk contents still match what we last wrote is refreshed
///   to the bundled version when that version changed (`updated`).
/// - A skill the user has hand-edited since our last write is left untouched and
///   reported (`skippedUserModified`) so the caller can surface it.
///
/// A manifest at `~/.codex/skills/.cmux-skills-manifest.json` records the app
/// build we last synced and the digest of each skill we wrote, which is what
/// lets us tell "untouched since our write" apart from "user-modified".
struct CmuxSkillsBundleInstaller {
    /// Per-run summary of what the sync changed.
    struct SyncOutcome: Equatable, Sendable {
        var installed: [String] = []
        var updated: [String] = []
        /// Skills we previously wrote and the user has since hand-edited. We
        /// leave these alone and surface them — the user's copy is now behind
        /// the bundled one and that's worth telling them about.
        var skippedUserModified: [String] = []
        /// Skills already on disk that we have no manifest record for (e.g. a
        /// manual `skills.sh` install, or a lost manifest) whose contents differ
        /// from the bundle. We can't prove the user edited them, so we leave
        /// them untouched but stay silent — claiming "you edited this" would be
        /// wrong for the common first-rollout migration case.
        var skippedUnmanaged: [String] = []
        var failed: [String] = []

        /// True when nothing on disk changed and nothing needs the user's
        /// attention — the common steady-state launch.
        var isNoOp: Bool {
            installed.isEmpty && updated.isEmpty && skippedUserModified.isEmpty
                && skippedUnmanaged.isEmpty && failed.isEmpty
        }
    }

    enum InstallerError: LocalizedError {
        case bundledSkillsMissing(expectedPath: String)

        var errorDescription: String? {
            switch self {
            case .bundledSkillsMissing(let expectedPath):
                return "Bundled skills directory was not found at \(expectedPath)."
            }
        }
    }

    private static let manifestFileName = ".cmux-skills-manifest.json"

    let fileManager: FileManager
    let destinationDirectoryURL: URL
    let appBuild: String
    private let bundledSkillsURLProvider: () -> URL?
    private let expectedBundledSkillsPath: String

    init(
        fileManager: FileManager = .default,
        destinationDirectoryURL: URL = CmuxSkillsBundleInstaller.defaultDestinationDirectoryURL(),
        appBuild: String = CmuxSkillsBundleInstaller.defaultAppBuild(),
        bundledSkillsURLProvider: @escaping () -> URL? = {
            CmuxSkillsBundleInstaller.defaultBundledSkillsURL()
        },
        expectedBundledSkillsPath: String = CmuxSkillsBundleInstaller.defaultBundledSkillsExpectedPath()
    ) {
        self.fileManager = fileManager
        self.destinationDirectoryURL = destinationDirectoryURL
        self.appBuild = appBuild
        self.bundledSkillsURLProvider = bundledSkillsURLProvider
        self.expectedBundledSkillsPath = expectedBundledSkillsPath
    }

    /// Reconcile every bundled skill into the destination directory, never
    /// overwriting user-modified skills. Safe to call on every launch.
    @discardableResult
    func sync() throws -> SyncOutcome {
        let bundledSkillsURL = try resolveBundledSkillsURL()
        let bundledSkillNames = try skillDirectoryNames(in: bundledSkillsURL)
        guard !bundledSkillNames.isEmpty else { return SyncOutcome() }

        try ensureDestinationDirectoryExists()
        var manifest = loadManifest()
        var outcome = SyncOutcome()

        for name in bundledSkillNames {
            let bundledSkillURL = bundledSkillsURL.appendingPathComponent(name, isDirectory: true)
            let destinationSkillURL = destinationDirectoryURL.appendingPathComponent(name, isDirectory: true)
            let bundledDigest = try directoryDigest(at: bundledSkillURL)

            do {
                if !fileManager.fileExists(atPath: destinationSkillURL.path) {
                    try copySkill(from: bundledSkillURL, to: destinationSkillURL)
                    manifest.skills[name] = bundledDigest
                    outcome.installed.append(name)
                    continue
                }

                let currentDigest = try directoryDigest(at: destinationSkillURL)
                if currentDigest == bundledDigest {
                    // Already current — record the digest so a later user edit is
                    // still detectable even if this is the first run with a manifest.
                    manifest.skills[name] = bundledDigest
                    continue
                }

                if let recordedDigest = manifest.skills[name] {
                    if recordedDigest == currentDigest {
                        // Untouched since our last write, but the bundled copy changed.
                        try copySkill(from: bundledSkillURL, to: destinationSkillURL)
                        manifest.skills[name] = bundledDigest
                        outcome.updated.append(name)
                    } else {
                        // We wrote it; the user has since edited it. Leave it be.
                        outcome.skippedUserModified.append(name)
                    }
                } else {
                    // On disk already but never written by us (manual skills.sh
                    // install or a lost manifest) and differing from the bundle.
                    // Can't prove a user edit — leave it untouched and silent.
                    outcome.skippedUnmanaged.append(name)
                }
            } catch {
                outcome.failed.append(name)
            }
        }

        manifest.appBuild = appBuild
        saveManifest(manifest)
        return outcome
    }

    // MARK: - Manifest

    private struct Manifest: Codable {
        var appBuild: String
        /// skill name -> digest of the contents we last wrote for that skill.
        var skills: [String: String]
    }

    private var manifestURL: URL {
        destinationDirectoryURL.appendingPathComponent(Self.manifestFileName, isDirectory: false)
    }

    private func loadManifest() -> Manifest {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return Manifest(appBuild: "", skills: [:])
        }
        return manifest
    }

    private func saveManifest(_ manifest: Manifest) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    // MARK: - Filesystem helpers

    /// Copy a skill into place without ever leaving the destination missing or
    /// half-written: stage the new copy in a sibling hidden temp directory, then
    /// swap it in. If staging fails, the existing skill is left untouched. The
    /// staging name is hidden so a crash mid-swap can't leave it looking like a
    /// real skill (`skillDirectoryNames`/`directoryDigest` skip hidden entries).
    private func copySkill(from sourceURL: URL, to destinationURL: URL) throws {
        let stagingURL = destinationDirectoryURL
            .appendingPathComponent(".cmux-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingURL) }
        try fileManager.copyItem(at: sourceURL, to: stagingURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }
    }

    private func ensureDestinationDirectoryExists() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destinationDirectoryURL.path, isDirectory: &isDirectory) {
            return
        }
        try fileManager.createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true)
    }

    /// Names of the immediate skill subdirectories inside a `skills/` directory,
    /// ignoring dotfiles (manifest, `.DS_Store`, etc.).
    private func skillDirectoryNames(in skillsURL: URL) throws -> [String] {
        let entries = try fileManager.contentsOfDirectory(
            at: skillsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// Content digest of a directory tree: a SHA-256 over each contained file's
    /// relative path and bytes, in sorted order, so identical trees hash equally
    /// regardless of enumeration order.
    private func directoryDigest(at directoryURL: URL) throws -> String {
        let standardizedRoot = directoryURL.standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ""
        }

        var fileURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            if (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                fileURLs.append(fileURL)
            }
        }

        let rootPath = standardizedRoot.path
        let entries: [(relativePath: String, fileURL: URL)] = fileURLs.map { fileURL in
            let absolute = fileURL.standardizedFileURL.path
            let relative = absolute.hasPrefix(rootPath + "/")
                ? String(absolute.dropFirst(rootPath.count + 1))
                : fileURL.lastPathComponent
            return (relative, fileURL)
        }
        .sorted { $0.relativePath < $1.relativePath }

        var hasher = SHA256()
        for entry in entries {
            hasher.update(data: Data(entry.relativePath.utf8))
            hasher.update(data: Data([0]))
            let fileData = try Data(contentsOf: entry.fileURL)
            hasher.update(data: withUnsafeBytes(of: UInt64(fileData.count).littleEndian) { Data($0) })
            hasher.update(data: fileData)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func resolveBundledSkillsURL() throws -> URL {
        guard let sourceURL = bundledSkillsURLProvider()?.standardizedFileURL else {
            throw InstallerError.bundledSkillsMissing(expectedPath: expectedBundledSkillsPath)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw InstallerError.bundledSkillsMissing(expectedPath: sourceURL.path)
        }
        return sourceURL
    }

    // MARK: - Defaults

    static func defaultDestinationDirectoryURL(fileManager: FileManager = .default) -> URL {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        if let codexHome, !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome, isDirectory: true)
                .appendingPathComponent("skills", isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/skills", isDirectory: true)
    }

    static func defaultAppBuild(bundle: Bundle = .main) -> String {
        bundle.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    static func defaultBundledSkillsURL(bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appendingPathComponent("skills", isDirectory: true)
    }

    static func defaultBundledSkillsExpectedPath(bundle: Bundle = .main) -> String {
        bundle.bundleURL
            .appendingPathComponent("Contents/Resources/skills", isDirectory: true)
            .path
    }
}
