internal import CmuxMobileDiagnostics
import Foundation

/// Reports DeviceLink client events into the app's retrievable file log.
///
/// The client runs below the composite, where the shared logger is not in
/// scope; without this, a credential that fails to load is silent and looks
/// like a network failure at the dial site.
// Stateless bridge to the app-owned diagnostic sink.
// lint:allow namespace-enum — it exposes no independently instantiable state.
enum MobileDeviceLinkDiagnostics {
    static func log(_ message: String) {
        MobileDebugLog.shared.append("devicelink · \(message)")
    }
}
