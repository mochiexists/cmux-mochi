import AppKit
import CmuxFoundation
import Combine
import Foundation

/// A panel that live-renders an artifact source file (React/TSX or HTML) and
/// reloads it whenever the file changes on disk — the cmux equivalent of a
/// Claude artifact. The source file lives in the global artifact store
/// (`~/.config/cmux/artifacts/`); see `ArtifactStore` and
/// `plans/feat-artifacts/PLAN.md`.
@MainActor
final class ArtifactPanel: Panel, ObservableObject {
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

    /// Token incremented to trigger the focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    // MARK: - File watching

    private var fileWatcher: FileWatcher?
    private var fileWatchTask: Task<Void, Never>?
    private var isClosed: Bool = false

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
        stopWatching()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - File I/O

    private func loadFileContent() {
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
