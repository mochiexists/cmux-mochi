import AppKit
import SwiftUI

/// SwiftUI host for an ``ArtifactPanel``.
///
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
                artifactContentView
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

    private var artifactContentView: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelFilePathHeader(
                iconSystemName: panel.displayIcon ?? "sparkles.rectangle.stack",
                filePath: panel.filePath,
                foregroundColor: appearance.foregroundColor
            ) {
                Text(panel.kind.displayName.uppercased())
                    .cmuxFont(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
                PanelHeaderIconButton(
                    systemName: panel.openExternallyIcon,
                    label: panel.openExternallyLabel,
                    isDisabled: !panel.canOpenRenderedPreviewExternally,
                    action: { panel.openRenderedPreviewExternally() }
                )
                PanelHeaderIconButton(
                    systemName: "square.and.arrow.down",
                    label: String(
                        localized: "artifact.saveToDownloads",
                        defaultValue: "Save to Downloads"
                    ),
                    isDisabled: !panel.canSaveToDownloads,
                    action: { panel.saveToDownloads() }
                )
            }

            Divider()

            if panel.kind.rendersInWebView {
                ArtifactWebRenderer(
                    source: panel.source,
                    kind: panel.kind,
                    backgroundColor: appearance.contentBackgroundColor,
                    panelId: panel.id,
                    workspaceId: panel.workspaceId,
                    filePath: panel.filePath,
                    session: panel.rendererSession,
                    onRequestPanelFocus: onRequestPanelFocus
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileArtifactView
            }
        }
    }

    private var fileArtifactView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(String(localized: "artifact.fileReady", defaultValue: "This artifact is saved as a file."))
                .foregroundStyle(.primary)
            Text(String(
                localized: "artifact.fileReady.detail",
                defaultValue: "Open it with the system app or save a copy to Downloads."
            ))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.contentBackgroundColor))
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
