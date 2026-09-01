import CmuxAuthRuntime
import CmuxMobileSupport
import Foundation
import StackAuth
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

struct PairingView: View {
    @Binding var pairingCode: String
    let initialPresentation: PairingPresentation
    let connectionError: String?
    /// A shorter, actionable next-step line shown beneath ``connectionError``
    /// (for example "Check that the selected private route is active"). `nil`
    /// when the headline is already the full instruction.
    let connectionErrorGuidance: String?
    let connectPairingCode: () async -> Void
    let cancelPairing: () -> Void
    let cancel: () -> Void

    @State private var isShowingScanner: Bool
    @Environment(AuthCoordinator.self) private var authManager
    @Environment(\.analytics) private var analytics
    @Environment(\.tailscaleStatusMonitor) private var tailscaleStatusMonitor
    @State private var isPairing = false
    @State private var didStartScannerPairing = false
    @State private var pairingTaskID: UUID?
    @State private var pairingTask: Task<Void, Never>?

    init(
        pairingCode: Binding<String>,
        initialPresentation: PairingPresentation = .scanner(entry: .settingsReplay),
        connectionError: String?,
        connectionErrorGuidance: String?,
        connectPairingCode: @escaping () async -> Void,
        cancelPairing: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        _pairingCode = pairingCode
        self.initialPresentation = initialPresentation
        self.connectionError = connectionError
        self.connectionErrorGuidance = connectionErrorGuidance
        self.connectPairingCode = connectPairingCode
        self.cancelPairing = cancelPairing
        self.cancel = cancel
        _isShowingScanner = State(initialValue: initialPresentation.showsScanner)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Fork (cmux Mochi): the QR scan IS the pairing flow, so it leads
                // the page under the fork's own mark. Upstream framed this page
                // account-first with the scan as an afterthought; on this fork the
                // Mac authorizes on the DeviceLink enrollment ticket in the QR, so
                // accounts and manual entry are the footnotes, not the headline.
                #if os(iOS)
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image("MochiLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 28, height: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.string("mobile.addDevice.fork.title", defaultValue: "cmux Mochi"))
                                .font(.headline)
                            Text(L10n.string(
                                "mobile.addDevice.fork.subtitle",
                                defaultValue: "No account needed. Scan the QR from your Mac's Pair a Device window and you're in."
                            ))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        isShowingScanner = true
                    } label: {
                        Label(L10n.string("mobile.pairing.scan", defaultValue: "Scan QR Code"), systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("MobileScanQRCodeButton")
                }
                #endif

                if PairingNetworkWarning.resolve(
                    status: tailscaleStatusMonitor?.status
                ) == .tailscaleDisconnected {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.string(
                                    "mobile.pairing.tailscaleDisconnected.title",
                                    defaultValue: "Tailscale isn't connected"
                                ))
                                .font(.headline)
                                Text(L10n.string(
                                    "mobile.pairing.tailscaleDisconnected.detail",
                                    defaultValue: "You can still pair on the same local network. Connect Tailscale only when the Mac isn't nearby."
                                ))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "network.slash")
                                .foregroundStyle(.orange)
                        }
                    }
                    .accessibilityIdentifier("MobilePairingTailscaleWarning")
                }

                #if DEBUG
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        // Fork (cmux Mochi): signed-out is the NORMAL state here, so
                        // no alarm iconography — QR pairing never touches an account.
                        Image(systemName: authManager.isAuthenticated ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                            .font(.title3)
                            .foregroundStyle(authManager.isAuthenticated ? .green : .secondary)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.string("mobile.addDevice.accountTitle", defaultValue: "Account (optional)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(signedInAccountText)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("MobileAddDeviceSignedInAccount")

                            Text(L10n.string("mobile.addDevice.accountHelp", defaultValue: "QR pairing never needs an account. Sign in only for push notifications and cross-device sync."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
                #endif

                if let errorText {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(errorText)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("MobilePairingError")
                            if let guidanceText = errorGuidanceText {
                                Text(guidanceText)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("MobilePairingErrorGuidance")
                            }
                            #if DEBUG
                            Text(signedInAccountText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("MobilePairingErrorSignedInAccount")
                            #endif
                        }
                    }
                }
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .navigationTitle(L10n.string("mobile.addDevice.title", defaultValue: "Add Computer"))
            .mobileInlineNavigationTitle()
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .cancellationAction) {
                    cancelButton
                }
                #else
                ToolbarItem {
                    cancelButton
                }
                #endif
            }
        }
        .accessibilityIdentifier("MobilePairingView")
        .overlay {
            if PairingAttemptPresentation.resolve(isPairing: isPairing) == .connecting {
                pairingProgressView
            }
        }
        #if os(iOS)
        .sheet(isPresented: $isShowingScanner) {
            scannerSheet
        }
        .onAppear {
            analytics.capture(
                "ios_pairing_screen_viewed",
                ["entry": .string(initialPresentation.analyticsEntry)]
            )
        }
        .onChange(of: initialPresentation) { _, presentation in
            if isPairing {
                cancelActivePairingTask()
                cancelPairing()
            }
            isShowingScanner = presentation.showsScanner
            analytics.capture(
                "ios_pairing_screen_viewed",
                ["entry": .string(presentation.analyticsEntry)]
            )
        }
        #endif
    }

    private var cancelButton: some View {
        Button {
            cancelActivePairingTask()
            cancelPairing()
            cancel()
        } label: {
            Text(L10n.string("mobile.common.cancel", defaultValue: "Cancel"))
        }
    }

    private var pairingProgressView: some View {
        ZStack {
            PlatformPalette.systemBackground
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)

                Text(L10n.string(
                    "mobile.pairing.progress.title",
                    defaultValue: "Pairing with your Mac"
                ))
                .font(.title3.weight(.semibold))

                Text(L10n.string(
                    "mobile.pairing.progress.detail",
                    defaultValue: "Connecting securely, verifying the pairing code, and saving this iPhone…"
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(32)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobilePairingProgress")
    }

    private func cancelActivePairingTask() {
        pairingTask?.cancel()
        pairingTaskID = nil
        pairingTask = nil
        isPairing = false
    }

    #if os(iOS)
    private var scannerSheet: some View {
        MobilePairingScannerSheet(
            previewEnabled: scannerPreviewEnabled,
            isPairing: isPairing,
            connectionError: connectionError,
            connectionErrorGuidance: connectionErrorGuidance,
            onCancel: scannerCancelAction,
            onEnterManually: nil,
            onRetry: retryScannerPairing
        ) { scannedCode in
            didStartScannerPairing = true
            pairingCode = scannedCode
            startPairingTask {
                await connectPairingCode()
            }
        }
    }

    private var scannerCancelAction: (() -> Void)? {
        guard initialPresentation.showsScanner else { return nil }
        #if DEBUG
        if initialPresentation == .scanner(entry: .settingsReplay) {
            return {
                cancelScannerPairingIfNeeded()
                isShowingScanner = false
            }
        }
        #endif
        return {
            cancelScannerPairingIfNeeded()
            cancelDirectScanner()
        }
    }

    private var scannerPreviewEnabled: Bool {
        #if DEBUG
        return UITestConfig.pairingScannerPreviewEnabled
        #else
        return false
        #endif
    }

    private func retryScannerPairing() {
        cancelScannerPairingIfNeeded()
    }

    private func cancelScannerPairingIfNeeded() {
        guard didStartScannerPairing else { return }
        cancelActivePairingTask()
        cancelPairing()
        didStartScannerPairing = false
    }
    #endif

    private var errorText: String? {
        connectionError
    }

    private var errorGuidanceText: String? {
        connectionErrorGuidance
    }

    private var signedInAccountText: String {
        guard authManager.isAuthenticated else {
            return L10n.string(
                "mobile.addDevice.notSignedIn",
                defaultValue: "Not signed in on this device."
            )
        }
        guard let email = authManager.currentUser?.primaryEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else {
            return L10n.string(
                "mobile.addDevice.signedInUnknown",
                defaultValue: "Signed in, email unavailable."
            )
        }
        let format = L10n.string(
            "mobile.addDevice.signedInFormat",
            defaultValue: "Signed in as %@"
        )
        return String(format: format, email)
    }

    private func startPairingTask(_ operation: @escaping @MainActor () async -> Void) {
        pairingTask?.cancel()
        let taskID = UUID()
        pairingTaskID = taskID
        isPairing = true
        let task = Task { @MainActor in
            defer {
                if pairingTaskID == taskID {
                    isPairing = false
                    pairingTaskID = nil
                    pairingTask = nil
                }
            }
            await operation()
        }
        pairingTask = task
    }

    private func cancelDirectScanner() {
        cancel()
    }
}
