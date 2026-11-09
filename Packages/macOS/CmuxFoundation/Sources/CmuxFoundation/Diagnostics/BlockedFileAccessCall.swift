/// A file-access system call a stalled thread is parked in, recognised from
/// the symbol at the thread's program counter.
///
/// macOS consults privacy (TCC) policy inside these calls, so a thread found
/// in one during a hang is most likely waiting for an unanswered privacy
/// prompt. On 2026-11-08 cmux's main thread sat in `openat` for ~50 minutes.
///
/// ```swift
/// BlockedFileAccessCall(symbol: "__openat_nocancel")?.syscall // "openat"
/// BlockedFileAccessCall(symbol: "mach_msg2_trap")             // nil
/// ```
public struct BlockedFileAccessCall: Sendable, Equatable {
    /// The normalised call name, such as `openat` or `getattrlist`.
    public let syscall: String

    /// The hang-metadata tag for this call, such as `main-thread-in-openat`.
    public var mainThreadTag: String { "main-thread-in-\(syscall)" }

    private static let fileAccessSyscalls: Set<String> = [
        "open", "openat", "open_dprotected_np", "openbyid_np",
        "stat", "stat64", "lstat", "lstat64", "fstatat", "fstatat64",
        "access", "faccessat",
        "getattrlist", "getattrlistat", "getattrlistbulk", "fgetattrlist",
        "getdirentries64", "chdir", "realpath", "realpath_darwin_extsn",
    ]

    /// Recognises a file-access call from a libsystem symbol name.
    ///
    /// Leading underscores, a `$NOCANCEL`/`$UNIX2003` variant suffix and a
    /// `_nocancel` suffix are ignored.
    ///
    /// - Parameter symbol: The symbol at the thread's program counter.
    /// - Returns: `nil` when the symbol is not a file-access call.
    public init?(symbol: String) {
        var name = Substring(symbol)
        if let variant = name.firstIndex(of: "$") {
            name = name[..<variant]
        }
        while name.first == "_" {
            name = name.dropFirst()
        }
        let nocancel = "_nocancel"
        if name.hasSuffix(nocancel) {
            name = name.dropLast(nocancel.count)
        }
        guard Self.fileAccessSyscalls.contains(String(name)) else { return nil }
        syscall = String(name)
    }
}
