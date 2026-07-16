import Foundation
import AppKit

/// Panel-owned renderer session for artifact previews.
///
/// SwiftUI may recreate `ArtifactWebRenderer` wrappers during split/tab layout
/// updates. The session keeps the WebKit coordinator identity tied to the
/// logical `ArtifactPanel`, so the WKWebView survives layout churn.
@MainActor
final class ArtifactRendererSession {
    private let ownedCoordinator = ArtifactWebRendererCoordinator()

    func coordinator(
        panelId: UUID,
        workspaceId: UUID,
        filePath: String
    ) -> ArtifactWebRendererCoordinator {
        ownedCoordinator.bind(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
        return ownedCoordinator
    }

    func close() {
        ownedCoordinator.close()
    }

    /// View to composite into workspace-level captures; nil until the web renderer mounts.
    var captureView: NSView? {
        ownedCoordinator.webView
    }

    func captureVisibleSnapshot(completion: @escaping (Result<NSImage, Error>) -> Void) {
        ownedCoordinator.captureVisibleSnapshot(completion: completion)
    }

    func renderedText(completion: @escaping (Result<String, Error>) -> Void) {
        ownedCoordinator.renderedText(completion: completion)
    }
}
