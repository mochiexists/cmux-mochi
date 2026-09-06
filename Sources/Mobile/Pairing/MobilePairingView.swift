import AppKit
import CmuxFoundation
import SwiftUI

/// The macOS onboarding window for pairing another cmux device with this Mac.
///
/// Shows the account-free DeviceLink QR once this Mac has a phone-reachable
/// authenticated private-LAN or Tailscale route.
struct MobilePairingView: View {
    private enum NetworkReachability {
        case localAndTailscale
        case local
        case tailscale
        case unavailable
    }

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
            Text(String(localized: "mobile.pairing.window.heading", defaultValue: "Pair a device"))
                .cmuxFont(.title2, weight: .semibold)
            Text(String(
                localized: "mobile.pairing.window.deviceLinkSubheading",
                defaultValue: "Connect both devices to the same local network or Tailscale network, then scan the code or copy the pairing link into cmux."
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
            networkRow
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
                defaultValue: "No cmux account is involved. This one-time code authorizes the other device directly."
            )
        ) {
            EmptyView()
        }
    }

    private var networkRow: some View {
        let reachability = networkReachability
        return requirementRow(
            title: String(
                localized: "mobile.pairing.req.network.title",
                defaultValue: "Network path"
            ),
            subtitle: networkSubtitle(reachability)
        ) {
            if reachability == .unavailable {
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

    private var networkReachability: NetworkReachability? {
        switch model.state {
        case let .ready(ready), let .expired(ready), let .connected(ready):
            if !ready.localNetworkLines.isEmpty, !ready.tailscaleLines.isEmpty {
                return .localAndTailscale
            }
            if !ready.localNetworkLines.isEmpty { return .local }
            if !ready.tailscaleLines.isEmpty { return .tailscale }
            return .unavailable
        case .needsReachableTransport: return .unavailable
        default: return nil
        }
    }

    private func networkSubtitle(_ reachability: NetworkReachability?) -> String {
        switch reachability {
        case .localAndTailscale:
            return String(
                localized: "mobile.pairing.req.network.localAndTailscale",
                defaultValue: "Reachable on your local network, with Tailscale available as fallback."
            )
        case .local:
            return String(
                localized: "mobile.pairing.req.network.local",
                defaultValue: "Reachable on your local network."
            )
        case .tailscale:
            return String(
                localized: "mobile.pairing.req.tailscale.reachable",
                defaultValue: "Reachable over Tailscale."
            )
        case .unavailable:
            return String(
                localized: "mobile.pairing.req.network.missing",
                defaultValue: "No private local-network or Tailscale route was detected."
            )
        case .none:
            return String(
                localized: "mobile.pairing.req.network.hint",
                defaultValue: "Local network is fastest; Tailscale remains available when you are away."
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
        case .expired:
            expiredContent
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
                localized: "mobile.pairing.needsNetwork.body",
                defaultValue: "No reachable route is available. Join the same local network or connect both devices to Tailscale, then refresh."
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

    private var expiredContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.exclamationmark")
                .cmuxFont(size: 28)
                .foregroundStyle(.orange)
            Text(String(
                localized: "mobile.pairing.expired.title",
                defaultValue: "Pairing code expired"
            ))
            .cmuxFont(.headline)
            Text(String(
                localized: "mobile.pairing.expired.body",
                defaultValue: "Pairing codes are single-use and valid for 10 minutes. Refresh before scanning again."
            ))
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            Button(String(localized: "mobile.pairing.refresh", defaultValue: "Refresh Code")) {
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
                Text(String(localized: "mobile.pairing.waiting", defaultValue: "Waiting for the other device…"))
                    .cmuxFont(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)

        steps

        HStack {
            Button(String(
                localized: "mobile.pairing.copyLink",
                defaultValue: "Copy Pairing Link"
            )) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ready.attachURL, forType: .string)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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
