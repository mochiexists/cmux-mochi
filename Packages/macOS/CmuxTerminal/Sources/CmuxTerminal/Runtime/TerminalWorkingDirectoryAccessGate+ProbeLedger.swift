extension TerminalWorkingDirectoryAccessGate {
    /// Lock-guarded bookkeeping that settles the race between a probe
    /// finishing and its caller giving up at the deadline.
    ///
    /// Both sides act under the gate's lock: a result that lands before the
    /// caller looks is collected; a probe that finishes after its caller gave
    /// up only clears its stall mark.
    struct ProbeLedger {
        private var nextProbeID: UInt64 = 0
        private var results: [UInt64: Bool] = [:]
        private(set) var stalledProbes: Set<UInt64> = []

        mutating func startProbe() -> UInt64 {
            nextProbeID += 1
            return nextProbeID
        }

        mutating func finishProbe(_ probeID: UInt64, opened: Bool) {
            if stalledProbes.remove(probeID) == nil {
                results[probeID] = opened
            }
        }

        /// Returns the probe's result, or marks it stalled and returns `nil`.
        mutating func collectOrAbandon(_ probeID: UInt64) -> Bool? {
            if let opened = results.removeValue(forKey: probeID) {
                return opened
            }
            stalledProbes.insert(probeID)
            return nil
        }
    }
}
