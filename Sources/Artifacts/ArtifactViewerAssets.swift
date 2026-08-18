import Foundation

#if DEBUG
private func artifactViewerAssetsLog(_ message: @autoclosure () -> String) {
    NSLog("%@", message() as NSString)
}
#endif

/// Loads the bundled artifact renderer shell from `Resources/artifact-viewer`.
@MainActor
final class ArtifactViewerAssets {
    static let shared = ArtifactViewerAssets()

    private let shellTemplate: String
    private let localizedStringsJSON: String

    private init() {
        shellTemplate = ArtifactViewerAssets.loadAsset(name: "shell", ext: "html")
        localizedStringsJSON = ArtifactViewerAssets.localizedStringsJSON()
    }

    func shellHTML() -> String {
        shellTemplate.replacingOccurrences(
            of: "{{localizedStringsJSON}}",
            with: localizedStringsJSON
        )
    }

    private static func loadAsset(name: String, ext: String) -> String {
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: name, withExtension: ext, subdirectory: "artifact-viewer"),
            bundle.url(forResource: name, withExtension: ext)
        ]
        for case let url? in candidates {
            if let source = try? String(contentsOf: url, encoding: .utf8) {
                return source
            }
        }
#if DEBUG
        artifactViewerAssetsLog("ArtifactViewerAssets: missing bundled asset \(name).\(ext)")
#endif
        preconditionFailure("Missing bundled artifact viewer asset \(name).\(ext)")
    }

    private static func localizedStringsJSON() -> String {
        let strings = [
            "loading": String(
                localized: "artifact.web.loading",
                defaultValue: "Rendering artifact..."
            ),
            "loadFailed": String(
                localized: "artifact.web.loadFailed",
                defaultValue: "Artifact renderer failed to load."
            ),
            "renderFailed": String(
                localized: "artifact.web.renderFailed",
                defaultValue: "Artifact render failed"
            ),
            "missingDefaultExport": String(
                localized: "artifact.web.missingDefaultExport",
                defaultValue: "The artifact must export a default React component."
            ),
            "unsupportedKind": String(
                localized: "artifact.web.unsupportedKind",
                defaultValue: "This artifact kind is not renderable yet."
            )
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: strings),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
