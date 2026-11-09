import CmuxFoundation
import Foundation
import UserNotifications

/// Tells the user when the hang watchdog finds the main thread parked in a
/// file-access call, which almost always means an unanswered macOS privacy
/// prompt (2026-11-08: ~50 minutes in `openat`, ended by a force quit).
///
/// Called from the watchdog's background queue while the main thread is
/// stuck, so it must not touch main-actor state; it talks to
/// `UNUserNotificationCenter` directly and reuses one identifier so repeated
/// stalls replace rather than stack the banner.
struct MainThreadFileAccessStallNotifier: Sendable {
    static let requestIdentifier = "cmux.main-thread-file-access-stall"

    func notify(blockedIn call: BlockedFileAccessCall) {
        let content = UNMutableNotificationContent()
        content.title = String(
            localized: "mainThreadFileAccessStall.notification.title",
            defaultValue: "cmux is waiting on macOS file access"
        )
        content.body = String(
            localized: "mainThreadFileAccessStall.notification.body",
            defaultValue: "A privacy prompt may be open. Answer it and cmux will continue."
        )
        content.userInfo = ["blockedSyscall": call.syscall]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: Self.requestIdentifier,
                content: content,
                trigger: nil
            )
        )
    }
}
