public import Darwin

/// Reads the symbol another thread of this process is executing, without the
/// thread's cooperation.
///
/// The main-thread hang watchdog uses it from its background queue: a thread
/// parked in a system call has its program counter in that call's libsystem
/// stub, so the symbol names what the blocked main thread is waiting on
/// (see ``BlockedFileAccessCall``). The read is a snapshot; it does not
/// suspend the thread.
///
/// ```swift
/// // On the main thread, once at startup:
/// let mainThread = ThreadProgramCounterSymbolReader.currentThread()
/// // Later, from any queue:
/// mainThread.currentSymbol() // e.g. "__openat"
/// ```
public struct ThreadProgramCounterSymbolReader: Sendable {
    private let thread: thread_act_t

    /// Creates a reader for a Mach thread port of this task.
    ///
    /// - Parameter thread: The thread to read; the caller keeps it alive.
    public init(thread: thread_act_t) {
        self.thread = thread
    }

    /// Creates a reader for the calling thread.
    ///
    /// The reader holds the `mach_thread_self()` send right for the life of
    /// the process; create one per thread you watch, not one per read.
    public static func currentThread() -> Self {
        Self(thread: mach_thread_self())
    }

    /// The exported symbol containing the thread's program counter, or `nil`
    /// when the state cannot be read or the address has no symbol.
    public func currentSymbol() -> String? {
        guard let programCounter = programCounter(),
              let address = UnsafeRawPointer(bitPattern: programCounter) else {
            return nil
        }
        var info = Dl_info()
        guard dladdr(address, &info) != 0, let name = info.dli_sname else {
            return nil
        }
        return String(cString: name)
    }

    private func programCounter() -> UInt? {
#if arch(arm64)
        var state = arm_thread_state64_t()
        let flavor = ARM_THREAD_STATE64
#elseif arch(x86_64)
        var state = x86_thread_state64_t()
        let flavor = x86_THREAD_STATE64
#endif
        var count = mach_msg_type_number_t(
            MemoryLayout.size(ofValue: state) / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &state) { statePointer in
            statePointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, thread_state_flavor_t(flavor), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
#if arch(arm64)
        return UInt(state.__pc)
#elseif arch(x86_64)
        return UInt(state.__rip)
#endif
    }
}
