import CmuxMobilePairedMac
import Foundation

/// Immutable row and owner snapshot captured before a removal performs network I/O.
struct MobileComputerRemovalTarget: Sendable {
    let representativeID: String
    let primary: MobilePairedMac
    let rows: [MobilePairedMac]
    let scope: MobileShellScopeSnapshot

    var pairingIDs: Set<String> { Set(rows.map(\.id)) }
    var physicalDeviceIDs: Set<String> { Set(rows.map(\.macDeviceID)) }
}
