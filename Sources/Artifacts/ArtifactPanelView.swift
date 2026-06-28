import AppKit
import SwiftUI

/// SwiftUI host for an ``ArtifactPanel``.
///
/// Phase A renders the artifact source as plain text plus a status banner; the
/// live WKWebView runtime (esbuild-wasm + the pinned library allow-list) lands
/// in Phase B (see `plans/feat-artifacts/PLAN.md`).
struct ArtifactPanelView: View {
    @ObservedObject var panel: ArtifactPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0

    var body: some View {
        Group {
            if panel.isFileUnavailable {
                unavailableView
            } else {
                sourcePreview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            WorkspaceAttentionFlashRingView(opacity: focusFlashOpacity)
        }
        .onChange(of: panel.focusFlashToken) {
            triggerFocusFlashAnimation()
        }
        .contentShape(Rectangle())
        .onTapGesture { onRequestPanelFocus() }
    }

    private var sourcePreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles.rectangle.stack")
                Text(String(
                    localized: "artifact.placeholder.banner",
                    defaultValue: "Live artifact rendering arrives next — showing source for now."
                ))
                .font(.system(size: 11))
                Spacer()
                Text(panel.kind.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(.secondary)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView([.horizontal, .vertical]) {
                Text(panel.source.isEmpty ? " " : panel.source)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    private var unavailableView: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(String(
                localized: "artifact.unavailable",
                defaultValue: "This artifact file is missing or unreadable."
            ))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func triggerFocusFlashAnimation() {
        focusFlashOpacity = 0.6
        withAnimation(.easeOut(duration: FocusFlashPattern.duration)) {
            focusFlashOpacity = 0.0
        }
    }
}
