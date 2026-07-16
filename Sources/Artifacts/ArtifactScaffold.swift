import Foundation

/// Starter source for a brand-new artifact. Kept deliberately tiny — a valid,
/// immediately-rendering default the user (or an agent) edits in place.
enum ArtifactScaffold {
    static func source(for kind: ArtifactKind, title: String) -> String {
        switch kind {
        case .react:
            return reactSource(title: title)
        case .html:
            return htmlSource(title: title)
        case .svg:
            return svgSource(title: title)
        case .mermaid:
            return mermaidSource(title: title)
        case .code:
            return codeSource(title: title)
        case .file:
            return ""
        case .swiftui:
            return swiftUISource(title: title)
        }
    }

    private static func reactSource(title: String) -> String {
        let safeTitle = escapedForJSX(title)
        return """
        import React, { useState } from "react";

        // cmux artifact — edit this file and the pane hot-reloads on save.
        export default function Artifact() {
          const [count, setCount] = useState(0);
          return (
            <div style={{ fontFamily: "system-ui", padding: 24 }}>
              <h1 style={{ marginTop: 0 }}>\(safeTitle)</h1>
              <p>Clicked {count} times.</p>
              <button onClick={() => setCount((c) => c + 1)}>Click me</button>
            </div>
          );
        }
        """
    }

    private static func htmlSource(title: String) -> String {
        let safeTitle = escapedForHTML(title)
        return """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8" />
            <title>\(safeTitle)</title>
            <style>
              body { font-family: system-ui; padding: 24px; }
            </style>
          </head>
          <body>
            <h1>\(safeTitle)</h1>
            <p>Edit this file — the pane hot-reloads on save.</p>
          </body>
        </html>
        """
    }

    private static func svgSource(title: String) -> String {
        let safeTitle = escapedForHTML(title)
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 720 360" role="img" aria-label="\(safeTitle)">
          <rect width="720" height="360" rx="24" fill="#0b1020"/>
          <circle cx="214" cy="180" r="88" fill="#5eead4" opacity="0.85"/>
          <circle cx="294" cy="180" r="88" fill="#60a5fa" opacity="0.75"/>
          <text x="360" y="194" text-anchor="middle" fill="white" font-family="system-ui" font-size="36" font-weight="700">\(safeTitle)</text>
        </svg>
        """
    }

    private static func mermaidSource(title: String) -> String {
        let safeTitle = title.replacingOccurrences(of: "\n", with: " ")
        return """
        flowchart LR
          A["\(safeTitle)"] --> B["Edit this file"]
          B --> C["The pane hot-reloads"]
        """
    }

    private static func codeSource(title: String) -> String {
        let safeTitle = title.replacingOccurrences(of: "\n", with: " ")
        return """
        // \(safeTitle)
        // Edit this file and the artifact pane hot-reloads on save.
        """
    }

    private static func swiftUISource(title: String) -> String {
        let safeTitle = escapedForSwift(title)
        return """
        import SwiftUI

        // cmux SwiftUI artifact (Phase 2 — rendering not yet wired).
        struct Artifact: View {
            var body: some View {
                VStack {
                    Text("\(safeTitle)").font(.title)
                }
                .padding()
            }
        }
        """
    }

    private static func escapedForJSX(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "{'{'}")
            .replacingOccurrences(of: "}", with: "{'}'}")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapedForHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapedForSwift(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
