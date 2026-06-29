import AppKit
import Foundation

enum ArtifactExternalPreview {
    private static let previewDirectoryName = "cmux-artifact-previews"

    static func supports(kind: ArtifactKind) -> Bool {
        kind.opensAsRenderedBrowserPreview
    }

    @MainActor
    static func writePreview(source: String, kind: ArtifactKind, filePath: String) throws -> URL {
        let html = try makePreviewDocument(
            shellHTML: ArtifactViewerAssets.shared.shellHTML(),
            source: source,
            kind: kind,
            filePath: filePath
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(previewDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let title = ((filePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let slug = ArtifactStore.slugify(title)
        let url = directory.appendingPathComponent("\(slug)-\(UUID().uuidString).html", isDirectory: false)
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func makePreviewDocument(
        shellHTML: String,
        source: String,
        kind: ArtifactKind,
        filePath: String
    ) throws -> String {
        let payload = [
            "source": source,
            "kind": kind.rawValue,
            "filePath": filePath
        ]
        let payloadJSON = try scriptSafeJSON(payload)
        let bootScript = """
        <script>
        (() => {
          const payload = \(payloadJSON);
          const render = () => {
            if (typeof window.__cmuxRenderArtifact === "function") {
              window.__cmuxRenderArtifact(payload);
            } else {
              window.requestAnimationFrame(render);
            }
          };
          if (document.readyState === "loading") {
            window.addEventListener("DOMContentLoaded", render, { once: true });
          } else {
            render();
          }
        })();
        </script>
        """
        guard let insertionIndex = outerBodyClosingIndex(in: shellHTML) else {
            return shellHTML + "\n" + bootScript
        }
        var document = shellHTML
        document.insert(contentsOf: "\n\(bootScript)\n", at: insertionIndex)
        return document
    }

    private static func outerBodyClosingIndex(in html: String) -> String.Index? {
        guard let shellScriptEnd = html.range(of: "</script>", options: .backwards) else {
            return html.range(of: "</body>", options: .backwards)?.lowerBound
        }
        return html.range(
            of: "</body>",
            options: [],
            range: shellScriptEnd.upperBound..<html.endIndex
        )?.lowerBound
    }

    private static func scriptSafeJSON(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard var json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        json = json.replacingOccurrences(of: "<", with: "\\u003c")
        json = json.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        json = json.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return json
    }
}
