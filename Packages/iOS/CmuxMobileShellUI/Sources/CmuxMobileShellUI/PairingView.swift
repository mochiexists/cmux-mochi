import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileShellModel
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
    let versionWarning: String?
    let connectPairingCode: () async -> Void
    let acceptVersionWarning: () async -> Void
    let connectManualHost: (String, String, Int) async -> Void
    let cancelPairing: () -> Void
    let cancel: () -> Void

    @State private var isShowingScanner: Bool
    @State private var deviceName = UITestConfig.addDeviceName
        ?? L10n.string("mobile.addDevice.namePlaceholder", defaultValue: "Work Mac")
    @State private var host = UITestConfig.addDeviceHost ?? ""
    @State private var port = UITestConfig.addDevicePort ?? "\(CmxMobileDefaults.defaultHostPort)"
    @Environment(AuthCoordinator.self) private var authManager
    @Environment(\.analytics) private var analytics
    @Environment(\.tailscaleStatusMonitor) private var tailscaleStatusMonitor
    @State private var validationError: String?
    @State private var isPairing = false
    @State private var pairingTaskID: UUID?
    @State private var pairingTask: Task<Void, Never>?
    @FocusState private var focusedField: AddDeviceField?

    init(
        pairingCode: Binding<String>,
        initialPresentation: PairingPresentation = .scanner(entry: .settingsReplay),
        connectionError: String?,
        connectionErrorGuidance: String?,
        versionWarning: String?,
        connectPairingCode: @escaping () async -> Void,
        acceptVersionWarning: @escaping () async -> Void,
        connectManualHost: @escaping (String, String, Int) async -> Void,
        cancelPairing: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        _pairingCode = pairingCode
        self.initialPresentation = initialPresentation
        self.connectionError = connectionError
        self.connectionErrorGuidance = connectionErrorGuidance
        self.versionWarning = versionWarning
        self.connectPairingCode = connectPairingCode
        self.acceptVersionWarning = acceptVersionWarning
        self.connectManualHost = connectManualHost
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
                                defaultValue: "No account needed. Scan the QR from your Mac's Pair iPhone window and you're in."
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
                                    defaultValue: "Open Tailscale on this iPhone and connect it before scanning the Mac's QR code."
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
                    TextField(
                        L10n.string("mobile.addDevice.namePlaceholder", defaultValue: "Work Mac"),
                        text: $deviceName
                    )
                    .focused($focusedField, equals: .name)
                    .submitLabel(.next)
                    .addDeviceInputBehavior(.text)
                    .accessibilityIdentifier("MobileAddDeviceNameField")

                    TextField(
                        L10n.string("mobile.addDevice.hostPlaceholder", defaultValue: "127.0.0.1 (simulator only)"),
                        text: $host
                    )
                    .focused($focusedField, equals: .host)
                    .submitLabel(.next)
                    .addDeviceInputBehavior(.url)
                    .accessibilityIdentifier("MobileAddDeviceHostField")

                    TextField(
                        L10n.string("mobile.addDevice.portPlaceholder", defaultValue: "58465"),
                        text: $port
                    )
                    .focused($focusedField, equals: .port)
                    .submitLabel(.done)
                    .addDeviceInputBehavior(.number)
                    .accessibilityIdentifier("MobileAddDevicePortField")
                } header: {
                    Text(L10n.string("mobile.addDevice.manualHeader", defaultValue: "Manual entry (development)"))
                } footer: {
                    Text(L10n.string(
                        "mobile.addDevice.help",
                        defaultValue: "You can paste a pairing link from the Mac into the host field. A bare host and port is for simulator development only."
                    ))
                }
                .overlay(alignment: .topLeading) {
                    if UITestConfig.mockDataEnabled {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(L10n.string("mobile.addDevice.formAccessibilityLabel", defaultValue: "Add Computer form"))
                            .accessibilityIdentifier("MobileAddDeviceForm")
                    }
                }

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

                            Text(L10n.string("mobile.addDevice.accountHelp", defaultValue: "QR pairing never needs an account. Sign in only for push notifications and cross-device sync \u{2014} or if you use manual host/port entry, which still requires one."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
                #endif

                #if DEBUG
                if let manualRouteWarningText {
                    Section {
                        Label {
                            Text(manualRouteWarningText)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("MobileManualRouteWarning")
                    }
                }
                #endif

                if let versionWarning {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label {
                                Text(L10n.string("mobile.pairing.versionWarningTitle", defaultValue: "Compatibility mismatch"))
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                            }
                            .font(.headline)
                            .foregroundStyle(.orange)

                            Text(versionWarning)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("MobilePairingVersionWarning")

                            Button(role: .destructive) {
                                startPairingTask {
                                    await acceptVersionWarning()
                                }
                            } label: {
                                Text(L10n.string("mobile.pairing.versionWarningContinue", defaultValue: "Continue anyway"))
                            }
                            .disabled(isPairing)
                            .accessibilityIdentifier("MobilePairingVersionWarningContinueButton")
                        }
                    }
                }

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
            #if DEBUG
            .safeAreaInset(edge: .bottom) {
                Button {
                    pair()
                } label: {
                    HStack {
                        Spacer(minLength: 0)
                        Text(L10n.string("mobile.addDevice.pair", defaultValue: "Pair"))
                            .mobileButtonLoading(isPairing, tint: .white)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.blue)
                .disabled(isPairing || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("MobilePairButton")
                .padding(.horizontal)
                .padding(.bottom, 8)
                .padding(.top, 24)
                .background {
                    PlatformPalette.systemBackground
                        .ignoresSafeArea(edges: .bottom)
                }
            }
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
                    defaultValue: "Connecting over Tailscale and saving this iPhone…"
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
            onCancel: scannerCancelAction,
            onEnterManually: scannerManualEntryAction
        ) { scannedCode in
            pairingCode = scannedCode
            isShowingScanner = false
            startPairingTask {
                await connectPairingCode()
            }
        }
    }

    private var scannerCancelAction: (() -> Void)? {
        guard initialPresentation.showsScanner else { return nil }
        #if DEBUG
        if initialPresentation == .scanner(entry: .settingsReplay) {
            return { isShowingScanner = false }
        }
        #endif
        return { cancelDirectScanner() }
    }

    private var scannerManualEntryAction: (() -> Void)? {
        #if DEBUG
        guard initialPresentation.showsScanner else { return nil }
        return { isShowingScanner = false }
        #else
        return nil
        #endif
    }

    private var scannerPreviewEnabled: Bool {
        #if DEBUG
        return UITestConfig.pairingScannerPreviewEnabled
        #else
        return false
        #endif
    }
    #endif

    private var errorText: String? {
        validationError ?? connectionError
    }

    /// The guidance line only belongs to a connection error. A local validation
    /// error (bad host/port) is self-explanatory and has no store-side guidance,
    /// so suppress the connection guidance while a validation error is showing.
    private var errorGuidanceText: String? {
        guard validationError == nil else { return nil }
        return connectionErrorGuidance
    }

    private var manualRouteWarningText: String? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty,
              !CmxPairingURLScheme.hasPairingScheme(trimmedHost),
              MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning(trimmedHost) else {
            return nil
        }
        return L10n.string(
            "mobile.addDevice.manualRouteWarning",
            defaultValue: "Manual host and port is for simulator development only. On a physical device, scan the Mac's Tailscale pairing code."
        )
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

    private func pair() {
        validationError = nil
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            validationError = L10n.string("mobile.addDevice.invalidHost", defaultValue: "Enter a host or IP address, without spaces or URL paths.")
            return
        }
        if CmxPairingURLScheme.hasPairingScheme(trimmedHost) {
            pairingCode = trimmedHost
            startPairingTask {
                await connectPairingCode()
            }
            return
        }
        guard MobileShellRouteAuthPolicy.normalizedManualHost(trimmedHost) != nil else {
            validationError = L10n.string("mobile.addDevice.invalidHost", defaultValue: "Enter a host or IP address, without spaces or URL paths.")
            return
        }
        guard let parsedPort = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(parsedPort) else {
            validationError = L10n.string("mobile.addDevice.invalidPort", defaultValue: "Enter a port from 1 to 65535.")
            return
        }

        startPairingTask {
            await connectManualHost(deviceName, trimmedHost, parsedPort)
        }
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

private enum AddDeviceField: Hashable {
    case name
    case host
    case port
}
