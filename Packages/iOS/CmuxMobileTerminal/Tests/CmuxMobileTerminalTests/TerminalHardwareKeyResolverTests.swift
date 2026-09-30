#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

@Suite("Terminal hardware key resolver")
struct TerminalHardwareKeyResolverTests {
    @Test("special keys resolve to exact terminal bytes", arguments: [
        (UIKeyCommand.inputEscape, UIKeyModifierFlags(), [0x1B]),
        ("\t", [], [0x09]),
        ("\t", [.shift], [0x1B, 0x5B, 0x5A]),
        (UIKeyCommand.inputUpArrow, [], [0x1B, 0x5B, 0x41]),
        (UIKeyCommand.inputDownArrow, [], [0x1B, 0x5B, 0x42]),
        (UIKeyCommand.inputRightArrow, [], [0x1B, 0x5B, 0x43]),
        (UIKeyCommand.inputLeftArrow, [], [0x1B, 0x5B, 0x44]),
        (UIKeyCommand.inputHome, [], [0x1B, 0x5B, 0x48]),
        (UIKeyCommand.inputEnd, [], [0x1B, 0x5B, 0x46]),
        (UIKeyCommand.inputPageUp, [], [0x1B, 0x5B, 0x35, 0x7E]),
        (UIKeyCommand.inputPageDown, [], [0x1B, 0x5B, 0x36, 0x7E]),
        (UIKeyCommand.inputLeftArrow, [.alternate], [0x1B, 0x62]),
        (UIKeyCommand.inputRightArrow, [.alternate], [0x1B, 0x66]),
        (UIKeyCommand.inputDelete, [.alternate], [0x1B, 0x7F]),
    ] as [(String, UIKeyModifierFlags, [UInt8])])
    func resolvesSpecialKey(input: String, modifiers: UIKeyModifierFlags, expected: [UInt8]) {
        #expect(TerminalHardwareKeyResolver.data(input: input, modifierFlags: modifiers) == Data(expected))
    }

    @Test("control keys resolve to exact control bytes", arguments: [
        ("c", UInt8(0x03)),
        ("d", 0x04),
        ("l", 0x0C),
        ("z", 0x1A),
        ("?", 0x7F),
    ])
    func resolvesControlKey(input: String, expected: UInt8) {
        let modifiers: UIKeyModifierFlags = input == "?" ? [.control, .shift] : [.control]
        #expect(TerminalHardwareKeyResolver.data(input: input, modifierFlags: modifiers) == Data([expected]))
    }

    @MainActor
    @Test("registered commands cover navigation and supported modifier combinations")
    func registersSupportedCommands() {
        let commands = TerminalHardwareKeyResolver.makeKeyCommands(
            target: CommandTarget(),
            action: #selector(CommandTarget.invoke(_:))
        )

        #expect(commands.contains { $0.input == UIKeyCommand.inputEscape && $0.modifierFlags.isEmpty })
        #expect(commands.contains { $0.input == "\t" && $0.modifierFlags == [.shift] })
        #expect(commands.contains { $0.input == UIKeyCommand.inputLeftArrow && $0.modifierFlags == [.alternate] })
        #expect(commands.contains { $0.input == "c" && $0.modifierFlags == [.control] })
        #expect(commands.contains { $0.input == "?" && $0.modifierFlags == [.control, .shift] })
        #expect(!commands.contains { $0.modifierFlags.contains(.command) })
    }
}

@MainActor
private final class CommandTarget: NSObject {
    @objc func invoke(_ sender: UIKeyCommand) {}
}
#endif
