import CmuxMobileCamera
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
#if os(iOS)
@preconcurrency import AVFoundation
import UIKit
#endif

#if os(iOS)
struct MobilePairingScannerSheet: View {
    let isPairing: Bool
    let connectionError: String?
    let connectionErrorGuidance: String?
    let versionWarning: String?
    let onCode: (String) -> Void
    let onCancel: (() -> Void)?
    let onEnterManually: (() -> Void)?
    let onRetry: () -> Void
    let onAcceptVersionWarning: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    private let authorization: CameraAuthorization
    private let previewEnabled: Bool
    @State private var authorizationStatus: AVAuthorizationStatus
    @State private var didScanCode = false
    @State private var scannerID = UUID()

    init(
        previewEnabled: Bool = false,
        isPairing: Bool,
        connectionError: String?,
        connectionErrorGuidance: String?,
        versionWarning: String?,
        onCancel: (() -> Void)? = nil,
        onEnterManually: (() -> Void)? = nil,
        onRetry: @escaping () -> Void,
        onAcceptVersionWarning: @escaping () -> Void,
        onCode: @escaping (String) -> Void
    ) {
        let authorization = CameraAuthorization()
        self.authorization = authorization
        self.previewEnabled = previewEnabled
        self.isPairing = isPairing
        self.connectionError = connectionError
        self.connectionErrorGuidance = connectionErrorGuidance
        self.versionWarning = versionWarning
        self.onCancel = onCancel
        self.onEnterManually = onEnterManually
        self.onRetry = onRetry
        self.onAcceptVersionWarning = onAcceptVersionWarning
        self.onCode = onCode
        _authorizationStatus = State(
            initialValue: previewEnabled ? .authorized : authorization.videoStatus
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if previewEnabled {
                    MobilePairingScannerPreview()
                } else {
                    switch presentation {
                    case .scanning:
                        scannerContent
                    case .connecting:
                        pairingProgress
                    case let .failed(message, guidance):
                        pairingFailure(message: message, guidance: guidance)
                    case let .versionWarning(message):
                        pairingVersionWarning(message: message)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                        onCancel?()
                    } label: {
                        Text(L10n.string("mobile.pairing.scannerCancel", defaultValue: "Cancel"))
                    }
                    .accessibilityIdentifier("MobileScannerCancelButton")
                }
            }
        }
        .accessibilityIdentifier("MobilePairingScannerSheet")
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !previewEnabled else { return }
            authorizationStatus = authorization.videoStatus
        }
    }

    private var presentation: MobilePairingScannerPresentation {
        MobilePairingScannerPresentation.resolve(
            didScanCode: didScanCode,
            isPairing: isPairing,
            error: connectionError,
            guidance: connectionErrorGuidance,
            versionWarning: versionWarning
        )
    }

    private var navigationTitle: String {
        if didScanCode {
            return L10n.string("mobile.pairing.navigationTitle", defaultValue: "Pairing")
        }
        return L10n.string("mobile.pairing.scannerTitle", defaultValue: "Scan QR Code")
    }

    @ViewBuilder
    private var scannerContent: some View {
        switch authorizationStatus {
        case .authorized:
            QRCodeScannerView { code in
                guard !didScanCode else { return }
                didScanCode = true
                onCode(code)
            }
            .id(scannerID)
            .ignoresSafeArea(edges: .bottom)
        case .notDetermined:
            ProgressView()
                .accessibilityIdentifier("MobilePairingScannerPermissionProgress")
                .task {
                    authorizationStatus = await authorization.requestVideoAccess()
                }
        case .denied:
            ContentUnavailableView {
                Label(
                    L10n.string(
                        "mobile.pairing.cameraDenied",
                        defaultValue: "Camera Access Required"
                    ),
                    systemImage: "camera.fill"
                )
            } description: {
                Text(L10n.string(
                    "mobile.pairing.cameraDeniedDescription",
                    defaultValue: "Allow camera access in Settings to scan the QR code from your Mac."
                ))
            } actions: {
                Button {
                    openSettings()
                } label: {
                    Text(L10n.string(
                        "mobile.pairing.openSettings",
                        defaultValue: "Open Settings"
                    ))
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("MobilePairingOpenSettingsButton")
                manualEntryButton
            }
            .accessibilityIdentifier("MobilePairingCameraDenied")
        case .restricted:
            ContentUnavailableView {
                Label(
                    L10n.string(
                        "mobile.pairing.cameraDenied",
                        defaultValue: "Camera Access Required"
                    ),
                    systemImage: "camera.fill"
                )
            } description: {
                Text(L10n.string(
                    "mobile.pairing.cameraRestrictedDescription",
                    defaultValue: """
                    Camera access is restricted on this device. Use a pairing link or the manual form instead.
                    """
                ))
            } actions: { manualEntryButton }
            .accessibilityIdentifier("MobilePairingCameraRestricted")
        @unknown default:
            ContentUnavailableView {
                Label(
                    L10n.string(
                        "mobile.pairing.cameraUnavailable",
                        defaultValue: "Camera Unavailable"
                    ),
                    systemImage: "camera.fill"
                )
            } actions: { manualEntryButton }
        }
    }

    private var pairingProgress: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)

            Text(L10n.string(
                "mobile.pairing.progress.title",
                defaultValue: "Pairing with your Mac"
            ))
            .font(.title3.weight(.semibold))

            Text(L10n.string(
                "mobile.pairing.progress.scannerDetail",
                defaultValue: "Connecting securely, verifying the pairing code, and saving this iPhone…"
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(32)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobilePairingScannerProgress")
    }

    private func pairingFailure(message: String, guidance: String?) -> some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.pairing.failed.title", defaultValue: "Pairing Failed"),
                systemImage: "exclamationmark.triangle.fill"
            )
        } description: {
            VStack(spacing: 8) {
                Text(message)
                    .accessibilityIdentifier("MobilePairingScannerError")
                if let guidance {
                    Text(guidance)
                        .accessibilityIdentifier("MobilePairingScannerErrorGuidance")
                }
            }
        } actions: {
            scanAgainButton
        }
        .accessibilityIdentifier("MobilePairingScannerFailure")
    }

    private func pairingVersionWarning(message: String) -> some View {
        ContentUnavailableView {
            Label(
                L10n.string(
                    "mobile.pairing.versionWarningTitle",
                    defaultValue: "Compatibility mismatch"
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
        } description: {
            Text(message)
                .accessibilityIdentifier("MobilePairingScannerVersionWarning")
        } actions: {
            Button(role: .destructive) {
                onAcceptVersionWarning()
            } label: {
                Text(L10n.string(
                    "mobile.pairing.versionWarningContinue",
                    defaultValue: "Continue anyway"
                ))
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("MobilePairingScannerVersionWarningContinueButton")
            scanAgainButton
        }
        .accessibilityIdentifier("MobilePairingScannerVersionWarningView")
    }

    private var scanAgainButton: some View {
        Button {
            onRetry()
            didScanCode = false
            scannerID = UUID()
        } label: {
            Text(L10n.string("mobile.pairing.scanAgain", defaultValue: "Scan Again"))
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("MobilePairingScanAgainButton")
    }

    @ViewBuilder
    private var manualEntryButton: some View {
        if let onEnterManually {
            Button {
                dismiss()
                onEnterManually()
            } label: {
                Text(L10n.string("mobile.pairing.enterManually", defaultValue: "Enter Manually"))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("MobilePairingEnterManuallyButton")
        }
    }

    private func openSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(settingsURL)
    }
}
#else
struct MobilePairingScannerSheet: View {
    let onCode: (String) -> Void

    var body: some View {
        ContentUnavailableView(
            L10n.string("mobile.pairing.cameraUnavailable", defaultValue: "Camera Unavailable"),
            systemImage: "camera.fill"
        )
    }
}
#endif
