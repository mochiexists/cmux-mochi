/// The scanner sheet state that remains visible after a QR code is recognized.
///
/// Keeping this state in the scanner prevents the parent pairing form from
/// rendering progress and failures behind the still-present camera sheet.
public enum MobilePairingScannerPresentation: Equatable, Sendable {
    case scanning
    case connecting
    case failed(message: String, guidance: String?)

    public static func resolve(
        didScanCode: Bool,
        isPairing: Bool,
        error: String?,
        guidance: String?
    ) -> Self {
        guard didScanCode else { return .scanning }

        // A retry can begin before the store clears the previous terminal
        // message. The active attempt owns presentation until it resolves.
        if isPairing {
            return .connecting
        }
        if let error {
            return .failed(message: error, guidance: guidance)
        }
        // There is a brief handoff between recognizing the QR code and the
        // parent task publishing its first state, and another while a successful
        // connection dismisses the parent sheet. Both are still progress.
        return .connecting
    }
}
