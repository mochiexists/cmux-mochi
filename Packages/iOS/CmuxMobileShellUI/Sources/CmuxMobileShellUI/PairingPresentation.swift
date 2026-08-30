/// The first pairing surface shown when the add-computer sheet opens.
enum PairingPresentation: Equatable {
    /// The manual name, host, and port form.
    case manual

    /// The QR scanner, with the manual form still available after a scan error.
    case scanner(entry: PairingAnalyticsEntry)

    var showsScanner: Bool {
        if case .scanner = self { return true }
        return false
    }

    var analyticsEntry: String {
        switch self {
        case .manual:
            "post_sign_in"
        case let .scanner(entry):
            entry.rawValue
        }
    }
}

/// Release-visible state for the interval after the scanner has accepted a QR
/// code and before the Mac has finished authorizing this iPhone.
enum PairingAttemptPresentation: Equatable {
    case idle
    case connecting

    static func resolve(isPairing: Bool) -> Self {
        isPairing ? .connecting : .idle
    }
}

enum PairingNetworkWarning: Equatable {
    case tailscaleDisconnected

    static func resolve(status: TailnetStatus?) -> Self? {
        status == .inactiveOrNotInstalled ? .tailscaleDisconnected : nil
    }
}
