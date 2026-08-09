/// Orders mobile-host transport startup so the required TCP listener is
/// available before optional Iroh policy and credential work is scheduled.
///
/// `scheduleIroh` must enqueue asynchronous activation and return immediately.
/// Keeping that boundary synchronous makes it impossible for a relay-policy or
/// Keychain suspension to delay the existing TCP listener.
// lint:allow namespace-type — pure startup-ordering seam whose injected
// closures fully describe each activation; an instance would retain no state.
public enum CmxIrohTCPFirstActivation {
    public static func start(
        startTCP: () -> Void,
        scheduleIroh: () -> Void
    ) {
        startTCP()
        scheduleIroh()
    }
}
