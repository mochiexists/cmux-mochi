import AppKit
import CmuxFoundation
import Combine
import Foundation

/// A panel that live-renders text-backed artifact files and treats generated
/// binary documents as downloadable/openable files — the cmux equivalent of a
/// Claude artifact. Files created by cmux live in the global artifact store
/// (`~/.config/cmux/artifacts/`); existing Claude artifact files can also be
/// opened directly. See `ArtifactStore` and `plans/feat-artifacts/PLAN.md`.
@MainActor
final class ArtifactPanel: Panel, ObservableObject, FileBackedPanel {
    let id: UUID
    let panelType: PanelType = .artifact

    /// Absolute path to the artifact source file being rendered.
    let filePath: String

    /// What the file renders as. Drives which runtime the web view loads.
    let kind: ArtifactKind

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Current source read from the file, pushed into the renderer on change.
    @Published private(set) var source: String = ""

    /// Title shown in the tab bar (the artifact filename).
    @Published private(set) var displayTitle: String = ""

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "sparkles.rectangle.stack" }

    /// Whether the file has been deleted or is unreadable.
    @Published private(set) var isFileUnavailable: Bool = false

    var canOpenRenderedPreviewExternally: Bool {
        !isFileUnavailable && (ArtifactExternalPreview.supports(kind: kind) || !kind.requiresTextSource)
    }

    var openExternallyLabel: String {
        if ArtifactExternalPreview.supports(kind: kind) {
            return String(
                localized: "artifact.openRenderedPreviewInBrowser",
                defaultValue: "Open Rendered Preview in Browser"
            )
        }
        return String(localized: "artifact.openFile", defaultValue: "Open File")
    }

    var openExternallyIcon: String {
        ArtifactExternalPreview.supports(kind: kind) ? "globe" : "arrow.up.right.square"
    }

    var canSaveToDownloads: Bool {
        !isFileUnavailable
    }

    /// Token incremented to trigger the focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// Stable renderer state so the WKWebView survives split/tab layout churn.
    let rendererSession = ArtifactRendererSession()

    // MARK: - File watching

    private var fileWatcher: FileWatcher?
    private var fileWatchTask: Task<Void, Never>?
    private var isClosed: Bool = false
    private var lastRevisionDigest: String?

    // MARK: - Init

    /// - Parameters:
    ///   - kind: when `nil`, inferred from the file extension via
    ///     ``ArtifactKind/kind(forFileExtension:)``, defaulting to `.react`.
    init(workspaceId: UUID, filePath: String, kind: ArtifactKind? = nil) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        let ext = (filePath as NSString).pathExtension
        self.kind = kind ?? ArtifactKind.kind(forFileExtension: ext) ?? .react
        self.displayTitle = (filePath as NSString).lastPathComponent

        loadFileContent()
        startWatching()
    }

    // MARK: - Panel protocol

    func focus() {
        // The web renderer owns first-responder once mounted (Phase B); no-op
        // until then.
    }

    func unfocus() {}

    func close() {
        isClosed = true
        rendererSession.close()
        stopWatching()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    func openRenderedPreviewExternally() {
        guard canOpenRenderedPreviewExternally else { return }
        guard ArtifactExternalPreview.supports(kind: kind) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
            return
        }
        do {
            let previewURL = try ArtifactExternalPreview.writePreview(
                source: source,
                kind: kind,
                filePath: filePath
            )
            NSWorkspace.shared.open(previewURL)
        } catch {
            NSLog("ArtifactPanel.openRenderedPreviewExternally failed: %@", "\(error)" as NSString)
        }
    }

    func saveToDownloads() {
        guard canSaveToDownloads else { return }
        do {
            let savedURL = try ArtifactDownload.copyToDownloads(originalFilePath: filePath)
            NSWorkspace.shared.activateFileViewerSelecting([savedURL])
        } catch {
            NSLog("ArtifactPanel.saveToDownloads failed: %@", "\(error)" as NSString)
        }
    }

    // MARK: - File I/O

    private func loadFileContent() {
        guard FileManager.default.fileExists(atPath: filePath) else {
            isFileUnavailable = true
            return
        }
        guard kind.requiresTextSource else {
            source = ""
            isFileUnavailable = false
            snapshotRevisionIfNeeded()
            return
        }
        guard let data = FileManager.default.contents(atPath: filePath) else {
            isFileUnavailable = true
            return
        }
        let decoded = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        guard let decoded else {
            isFileUnavailable = true
            return
        }
        source = decoded
        isFileUnavailable = false
        snapshotRevisionIfNeeded()
    }

    private func snapshotRevisionIfNeeded() {
        do {
            let result = try ArtifactVersionStore.snapshotIfChanged(
                filePath: filePath,
                lastDigest: lastRevisionDigest
            )
            lastRevisionDigest = result.digest
        } catch {
            NSLog("ArtifactPanel.snapshotRevisionIfNeeded failed: %@", "\(error)" as NSString)
        }
    }

    // MARK: - File watcher

    /// Watches ``filePath`` via ``CmuxFileWatch/FileWatcher`` (handles inode
    /// reattachment + nearest-existing-ancestor recovery); each change reloads
    /// the source so the rendered artifact hot-reloads on save.
    private func startWatching() {
        stopWatching()
        let watcher = FileWatcher(path: filePath)
        fileWatcher = watcher
        let events = watcher.events
        fileWatchTask = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self, !self.isClosed else { break }
                self.loadFileContent()
            }
        }
    }

    private func stopWatching() {
        fileWatchTask?.cancel()
        fileWatchTask = nil
        fileWatcher = nil
    }

    deinit {
        fileWatchTask?.cancel()
    }
}

enum ArtifactDownload {
    static func copyToDownloads(
        originalFilePath: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let downloadsDirectory = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
        return try copy(
            originalFilePath: originalFilePath,
            destinationDirectory: downloadsDirectory,
            fileManager: fileManager
        )
    }

    static func copy(
        originalFilePath: String,
        destinationDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let destinationURL = uniqueDestinationURL(
            in: destinationDirectory,
            originalFilePath: originalFilePath,
            fileManager: fileManager
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: URL(fileURLWithPath: originalFilePath), to: destinationURL)
        return destinationURL
    }

    static func writeToDownloads(
        source: String,
        originalFilePath: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let downloadsDirectory = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
        return try write(
            source: source,
            originalFilePath: originalFilePath,
            destinationDirectory: downloadsDirectory,
            fileManager: fileManager
        )
    }

    static func write(
        source: String,
        originalFilePath: String,
        destinationDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let destinationURL = uniqueDestinationURL(
            in: destinationDirectory,
            originalFilePath: originalFilePath,
            fileManager: fileManager
        )
        try Data(source.utf8).write(to: destinationURL, options: [.atomic])
        return destinationURL
    }

    private static func uniqueDestinationURL(
        in directory: URL,
        originalFilePath: String,
        fileManager: FileManager
    ) -> URL {
        let originalURL = URL(fileURLWithPath: originalFilePath)
        let filename = originalURL.lastPathComponent.isEmpty ? "artifact" : originalURL.lastPathComponent
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        let baseURL = directory.appendingPathComponent(filename, isDirectory: false)
        guard fileManager.fileExists(atPath: baseURL.path) else {
            return baseURL
        }

        for index in 2...999 {
            let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidateURL = directory.appendingPathComponent(candidateName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        let fallbackName = ext.isEmpty ? "\(stem)-\(UUID().uuidString)" : "\(stem)-\(UUID().uuidString).\(ext)"
        return directory.appendingPathComponent(fallbackName, isDirectory: false)
    }
}
