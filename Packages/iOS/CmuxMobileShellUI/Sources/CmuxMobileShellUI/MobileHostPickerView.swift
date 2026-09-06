#if os(iOS)
import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Lets the user switch which paired Mac this device controls, and pair another.
///
/// Lists every Mac paired with this device (from the on-device store), marks the
/// one the live connection targets, switches on tap, hides on swipe, and pairs
/// a new Mac by scanning its QR code without dropping the others.
struct MobileHostPickerView: View {
    @Bindable var store: CMUXMobileShellStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingScanner = false
    @State private var isPairing = false
    @State private var didStartScannerPairing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.pairedMacs.isEmpty {
                        Text(L10n.string("mobile.hostPicker.empty", defaultValue: "No computers yet. Tap Pair Another Computer and scan the QR code shown by cmux on your Mac. No account is required."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.pairedMacs) { mac in
                        macRow(mac)
                    }
                } header: {
                    Text(L10n.string("mobile.hostPicker.header", defaultValue: "Paired Computers"))
                } footer: {
                    Text(L10n.string(
                        "mobile.hostPicker.footer",
                        defaultValue: "Switch which computer this device controls. A computer joins this list automatically the first time this phone connects to it. Pair Another Computer adds more without removing the ones you have."
                    ))
                }

                Section {
                    Button {
                        didStartScannerPairing = false
                        showingScanner = true
                    } label: {
                        Label(
                            L10n.string("mobile.hostPicker.addMac", defaultValue: "Pair Another Computer"),
                            systemImage: "plus"
                        )
                    }
                    .accessibilityIdentifier("MobileHostPickerAddMac")
                }
            }
            .navigationTitle(L10n.string("mobile.hostPicker.title", defaultValue: "Switch Computer"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("MobileHostPickerDone")
                }
            }
            .task { await store.loadPairedMacs() }
            .sheet(isPresented: $showingScanner) {
                MobilePairingScannerSheet(
                    isPairing: isPairing,
                    connectionError: store.connectionError,
                    connectionErrorGuidance: store.connectionErrorGuidance,
                    onCancel: cancelScannerPairing,
                    onRetry: cancelScannerPairing,
                ) { code in
                    connectScannerCode(code)
                }
            }
        }
        .accessibilityIdentifier("MobileHostPicker")
    }

    private func connectScannerCode(_ code: String) {
        didStartScannerPairing = true
        isPairing = true
        Task {
            let result = await store.connectPairingURLResult(code)
            isPairing = false
            await finishScannerPairing(result)
        }
    }

    private func cancelScannerPairing() {
        guard didStartScannerPairing else { return }
        store.cancelPairing()
        isPairing = false
        didStartScannerPairing = false
    }

    private func finishScannerPairing(_ result: MobilePairingURLConnectionResult) async {
        guard result.didPair else { return }
        await store.loadPairedMacs()
        showingScanner = false
        dismiss()
    }

    @ViewBuilder
    private func macRow(_ mac: MobilePairedMac) -> some View {
        let isActive = mac.isActive
        let appDisplayName = localizedAppDisplayName(for: mac)
        let hasSiblingInstance = store.pairedMacs.contains {
            $0.id != mac.id && $0.macDeviceID == mac.macDeviceID
        }
        Button {
            Task {
                await store.switchToMac(
                    macDeviceID: mac.macDeviceID,
                    instanceTag: mac.instanceTag
                )
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(scopedDisplayName(mac.resolvedName))
                        .foregroundStyle(.primary)
                    if let appDisplayName {
                        Text(appDisplayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if hasSiblingInstance {
                        Text(L10n.string("mobile.hostPicker.app.legacy", defaultValue: "Legacy"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(mac.lastSeenAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel(L10n.string("mobile.hostPicker.active", defaultValue: "Active"))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("MobileHostPickerRow-\(mac.id)")
        .swipeActions(edge: .trailing) {
            Button {
                Task {
                    await store.hideStoredMac(
                        macDeviceID: mac.macDeviceID,
                        instanceTag: mac.instanceTag
                    )
                }
            } label: {
                Label(
                    L10n.string("mobile.hostPicker.hide", defaultValue: "Hide"),
                    systemImage: "eye.slash"
                )
            }
            .accessibilityIdentifier("MobileHostPickerHide-\(mac.id)")
        }
    }

    private func scopedDisplayName(_ baseName: String) -> String {
        MobileIOSBuildScope.current()?.computerDisplayName(baseName) ?? baseName
    }

    private func localizedAppDisplayName(for mac: MobilePairedMac) -> String? {
        guard let appName = MacBuildChannel().appDisplayName(
            bundleID: nil,
            tag: mac.instanceTag
        ) else {
            return nil
        }
        switch appName {
        case "cmux":
            return L10n.string("mobile.hostPicker.app.stable", defaultValue: "cmux")
        case "cmux Nightly":
            return L10n.string("mobile.hostPicker.app.nightly", defaultValue: "cmux Nightly")
        case "cmux RC":
            return L10n.string("mobile.hostPicker.app.rc", defaultValue: "cmux RC")
        case "cmux Staging":
            return L10n.string("mobile.hostPicker.app.staging", defaultValue: "cmux Staging")
        case "cmux DEV":
            return L10n.string("mobile.hostPicker.app.dev", defaultValue: "cmux DEV")
        default:
            let prefix = "cmux DEV "
            guard appName.hasPrefix(prefix) else { return appName }
            let tag = appName.dropFirst(prefix.count)
            let format = L10n.string(
                "mobile.hostPicker.app.devTaggedFormat",
                defaultValue: "cmux DEV %@"
            )
            return String(format: format, String(tag))
        }
    }
}
#endif
