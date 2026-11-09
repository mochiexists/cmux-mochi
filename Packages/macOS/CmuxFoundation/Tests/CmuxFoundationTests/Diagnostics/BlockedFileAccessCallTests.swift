import Testing
@testable import CmuxFoundation

@Suite
struct BlockedFileAccessCallTests {
    @Test(arguments: [
        ("__openat", "openat"),
        ("openat", "openat"),
        ("__openat_nocancel", "openat"),
        ("__open_nocancel", "open"),
        ("open$NOCANCEL", "open"),
        ("__stat64", "stat64"),
        ("fstatat64", "fstatat64"),
        ("getattrlist", "getattrlist"),
        ("__getattrlistbulk", "getattrlistbulk"),
    ])
    func recognisesFileAccessCalls(symbol: String, syscall: String) {
        let call = BlockedFileAccessCall(symbol: symbol)

        #expect(call?.syscall == syscall)
        #expect(call?.mainThreadTag == "main-thread-in-\(syscall)")
    }

    @Test(arguments: ["mach_msg2_trap", "__psynch_cvwait", "__semwait_signal", "read", "", "_"])
    func ignoresOtherCalls(symbol: String) {
        #expect(BlockedFileAccessCall(symbol: symbol) == nil)
    }
}
