import CmuxMobileShell
import CmuxMobileWorkspace
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

extension MobileRootAuthGate {
    /// Reflects Stack auth state into the legacy shell store's sign-in lifecycle.
    ///
    /// This bridge lives in the feature target because it reaches into the
    /// `CMUXMobileShellStore` god object, which sits above the pure
    /// ``MobileRootAuthGate`` policy in ``CmuxMobileWorkspace``.
    @MainActor
    static func syncShellAuthentication(
        stackAuthenticated: Bool,
        isRestoringSession: Bool = false,
        store: CMUXMobileShellStore
    ) {
        if stackAuthenticated {
            store.signIn()
            return
        }
        guard !isRestoringSession else { return }
        // Fork (cmux Mochi): a DeviceLink pairing is not a Stack session, and
        // never becomes one. Signing the shell out here because no account is
        // present revokes an authentication the account system never granted:
        // the device's own key is the credential.
        //
        // The damage is indirect and so was hard to read. Paired Macs are looked
        // up by scope, scope resolution requires a signed-in shell, so this made
        // the store return nothing — the UI reported "no computers paired" while
        // a DeviceLink connection was live underneath. On hardware it fired
        // ~49 s after a successful cold-launch reconnect.
        if MobileDeviceLinkClient.shared.hasAnyPairedDevice() {
            return
        }
        store.signOut()
    }
}
