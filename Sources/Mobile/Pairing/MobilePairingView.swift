import AppKit
import CmuxFoundation
import SwiftUI

/// The macOS onboarding window for pairing an iPhone with this Mac.
///
/// Shows the account-free DeviceLink QR once this Mac has a phone-reachable
/// Tailscale route.
struct MobilePairingView: View {
    @State private var model = MobilePairingModel()
    /// Reports the scroll content's unconstrained height so the AppKit window
    /// can grow to reveal it while retaining scrolling on shorter displays.
    private let onContentHeightChange: (CGFloat) -> Void

    private static let tailscaleDownloadURL = URL(string: "https://tailscale.com/download")!
    /// Where a Mac user goes to get cmux for iPhone while the beta is invite-only.
    static let iphoneAppURL = URL(string: "https://github.com/mochiexists/cmux-mochi#founders-edition")!

    init(onContentHeightChange: @escaping (CGFloat) -> Void = { _ in }) {
        self.onContentHeightChange = onContentHeightChange
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                requirements
                Divider()
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: MobilePairingContentHeightPreferenceKey.self,
                        value: MobilePairingContentMeasurement(
                            height: geometry.size.height,
                            state: model.state
                        )
                    )
                }
            }
        }
        .onPreferenceChange(MobilePairingContentHeightPreferenceKey.self) { measurement in
            onContentHeightChange(measurement.height)
        }
        .task { await model.refresh() }
        .onDisappear { model.stopObserving() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "mobile.pairing.window.heading", defaultValue: "Pair your iPhone"))
                .cmuxFont(.title2, weight: .semibold)
            Text(String(
                localized: "mobile.pairing.window.deviceLinkSubheading",
                defaultValue: "Connect this Mac and your iPhone to the same Tailscale network, then scan this code in the cmux app."
            ))
            .cmuxFont(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Requirements checklist

    private var requirements: some View {
        VStack(alignment: .leading, spacing: 12) {
            noAccountRow
            tailscaleRow
        }
    }

    private var noAccountRow: some View {
        requirementRow(
            title: String(
                localized: "mobile.pairing.req.account.optional.title",
                defaultValue: "No account needed"
            ),
            subtitle: String(
                localized: "mobile.pairing.req.account.optional.subtitle",
                defaultValue: "No cmux account is involved. This one-time code authorizes your iPhone directly."
            )
        ) {
            EmptyView()
        }
    }

    private var tailscaleRow: some View {
        let reachable = tailscaleReachable
        return requirementRow(
            title: String(
                localized: "mobile.pairing.req.tailscale.title",
                defaultValue: "Tailscale"
            ),
            subtitle: tailscaleSubtitle(reachable: reachable)
        ) {
            if reachable == false {
                Link(
                    String(
                        localized: "mobile.pairing.req.tailscale.get",
                        defaultValue: "Get Tailscale"
                    ),
                    destination: Self.tailscaleDownloadURL
                )
                .cmuxFont(.callout)
            }
        }
    }

    private var tailscaleReachable: Bool? {
        switch model.state {
        case let .ready(ready): return ready.reachableViaTailscale
        case let .connected(ready): return ready.reachableViaTailscale
        case .needsReachableTransport: return false
        default: return nil
        }
    }

    private func tailscaleSubtitle(reachable: Bool?) -> String {
        switch reachable {
        case .some(true):
            return String(
                localized: "mobile.pairing.req.tailscale.reachable",
                defaultValue: "Reachable over Tailscale."
            )
        case .some(false):
            return String(
                localized: "mobile.pairing.req.tailscale.missing",
                defaultValue: "Not detected. Install Tailscale on this Mac and your iPhone, signed in to the same account."
            )
        case .none:
            return String(
                localized: "mobile.pairing.req.tailscale.hint",
                defaultValue: "Your Mac and iPhone both need Tailscale to connect over the internet."
            )
        }
    }

    private func requirementRow<Trailing: View>(
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).cmuxFont(.callout, weight: .medium)
                Text(subtitle)
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }

    // MARK: Gated content

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            loadingContent
        case .preparing:
            centered {
                ProgressView().controlSize(.small)
                Text(String(localized: "mobile.pairing.preparing", defaultValue: "Preparing a pairing code…"))
                    .foregroundStyle(.secondary)
            }
        case .needsReachableTransport:
            needsReachableTransportContent
        case let .failed(message):
            failure(message: message)
        case let .ready(ready):
            readyContent(ready)
        case let .connected(ready):
            connectedContent(ready)
        }
    }

    private var needsReachableTransportContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "network.slash")
                .cmuxFont(size: 28)
                .foregroundStyle(.orange)
            Text(String(
                localized: "mobile.pairing.needsTailscale.body",
                defaultValue: "No Tailscale route is available. Connect this Mac and your iPhone to the same Tailscale network, then refresh."
            ))
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Link(
                String(localized: "mobile.pairing.req.tailscale.get", defaultValue: "Get Tailscale"),
                destination: Self.tailscaleDownloadURL
            )
            .buttonStyle(.borderedProminent)
            Button(String(localized: "mobile.pairing.refresh", defaultValue: "Refresh Code")) {
                Task { await model.refresh() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var loadingContent: some View {
        centered {
            ProgressView().controlSize(.small)
            Text(String(localized: "mobile.pairing.checking", defaultValue: "Checking…"))
                .foregroundStyle(.secondary)
        }
    }

    private func failure(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .cmuxFont(size: 28)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(String(localized: "mobile.pairing.retry", defaultValue: "Try Again")) {
                Task { await model.refresh() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    @ViewBuilder
    private func readyContent(_ ready: MobilePairingModel.Ready) -> some View {
        VStack(alignment: .center, spacing: 14) {
            // The spec 4-module quiet zone (white margin) is baked into the QR
            // bitmap itself, so the code gets no extra white card padding here:
            // the old 12pt-padded white card doubled the visible quiet zone.
            // Width is capped so the whole QR and waiting indicator fit the
            // default window without scrolling.
            MobilePairingQRImageView(payload: ready.attachURL)
                .frame(maxWidth: 380)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2))
                )

            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(localized: "mobile.pairing.waiting", defaultValue: "Waiting for your iPhone…"))
                    .cmuxFont(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)

        steps

        HStack {
            Spacer()
            Button(String(localized: "mobile.pairing.refresh", defaultValue: "Refresh Code")) {
                Task { await model.refresh() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

private struct MobilePairingContentMeasurement: Equatable {
    let height: CGFloat
    let state: MobilePairingModel.State
}

private struct MobilePairingContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue = MobilePairingContentMeasurement(
        height: 0,
        state: .loading
    )

    static func reduce(
        value: inout MobilePairingContentMeasurement,
        nextValue: () -> MobilePairingContentMeasurement
    ) {
        let next = nextValue()
        if next.height >= value.height {
            value = next
        }
    }
}
