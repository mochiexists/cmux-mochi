import AppKit
import SwiftUI

struct WorkspaceSurfaceIdentifierDetailsView: View {
    let details: WorkspaceSurfaceIdentifierDetails
    let onClose: () -> Void
    @State private var copiedKey: String?

    private let sectionOrder: [WorkspaceSurfaceIdentifierDetailsSection] = [.refs, .ids, .agent]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sectionOrder, id: \.self) { section in
                        let rows = details.rows.filter { $0.section == section }
                        if !rows.isEmpty {
                            sectionView(section, rows: rows)
                        }
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 620, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: copiedKey) {
            await resetCopiedKeyAfterDisplayInterval(copiedKey)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "identifierDetails.title", defaultValue: "Surface IDs"))
                    .font(.headline)
                Text(
                    String(
                        localized: "identifierDetails.subtitle",
                        defaultValue: "Copy identifiers, agent session data, or the resume command."
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                copy(details.clipboardText, key: "all")
            } label: {
                Label(
                    String(localized: "identifierDetails.copyAll", defaultValue: "Copy All"),
                    systemImage: copiedKey == "all" ? "checkmark" : "doc.on.doc"
                )
            }
            .disabled(!details.hasCopyableRows)
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "identifierDetails.close", defaultValue: "Close"))
            .accessibilityLabel(String(localized: "identifierDetails.close", defaultValue: "Close"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func sectionView(
        _ section: WorkspaceSurfaceIdentifierDetailsSection,
        rows: [WorkspaceSurfaceIdentifierDetails.Row]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title(for: section))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    rowView(row)
                    if row.id != rows.last?.id {
                        Divider()
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
        }
    }

    private func rowView(_ row: WorkspaceSurfaceIdentifierDetails.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.key)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(row.value ?? String(localized: "identifierDetails.unavailable", defaultValue: "Unavailable"))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(row.value == nil ? .tertiary : .primary)
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if let copyLine = row.copyLine {
                    copy(copyLine, key: row.key)
                }
            } label: {
                Image(systemName: copiedKey == row.key ? "checkmark" : "doc.on.doc")
            }
            .disabled(row.value == nil)
            .buttonStyle(.borderless)
            .help(String(localized: "identifierDetails.copyLine", defaultValue: "Copy line"))
            .accessibilityLabel(String(localized: "identifierDetails.copyLine", defaultValue: "Copy line"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func title(for section: WorkspaceSurfaceIdentifierDetailsSection) -> String {
        switch section {
        case .refs:
            return String(localized: "identifierDetails.refsSection", defaultValue: "Refs")
        case .ids:
            return String(localized: "identifierDetails.idsSection", defaultValue: "IDs")
        case .agent:
            return String(localized: "identifierDetails.agentSection", defaultValue: "Agent")
        }
    }

    private func copy(_ text: String, key: String) {
        guard !text.isEmpty else { return }
        WorkspaceSurfaceIdentifierClipboardText.copy(text)
        copiedKey = key
    }

    @MainActor
    private func resetCopiedKeyAfterDisplayInterval(_ key: String?) async {
        guard let key else { return }
        // Intended copied-feedback duration; SwiftUI cancels it when the key changes.
        try? await Task.sleep(for: .milliseconds(1200))
        guard !Task.isCancelled, copiedKey == key else { return }
        copiedKey = nil
    }
}
