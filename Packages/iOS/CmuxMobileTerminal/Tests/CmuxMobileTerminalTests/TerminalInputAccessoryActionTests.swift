#if canImport(UIKit)
import Foundation
import Testing
@testable import CmuxMobileTerminal

@Suite("Terminal input accessory actions")
struct TerminalInputAccessoryActionTests {
    @Test("key-bar actions expose exact terminal bytes", arguments: [
        (TerminalInputAccessoryAction.escape, [0x1B]),
        (.tab, [0x09]),
        (.upArrow, [0x1B, 0x5B, 0x41]),
        (.downArrow, [0x1B, 0x5B, 0x42]),
        (.rightArrow, [0x1B, 0x5B, 0x43]),
        (.leftArrow, [0x1B, 0x5B, 0x44]),
        (.ctrlC, [0x03]),
        (.ctrlD, [0x04]),
        (.ctrlL, [0x0C]),
        (.ctrlZ, [0x1A]),
        (.home, [0x1B, 0x5B, 0x48]),
        (.end, [0x1B, 0x5B, 0x46]),
        (.pageUp, [0x1B, 0x5B, 0x35, 0x7E]),
        (.pageDown, [0x1B, 0x5B, 0x36, 0x7E]),
    ] as [(TerminalInputAccessoryAction, [UInt8])])
    func fixedOutput(action: TerminalInputAccessoryAction, expected: [UInt8]) {
        #expect(action.output == Data(expected))
    }

    @Test("modifier actions arm instead of emitting fixed bytes", arguments: [
        TerminalInputAccessoryAction.control,
        .alternate,
        .command,
        .shift,
    ])
    func modifiersHaveNoFixedOutput(action: TerminalInputAccessoryAction) {
        #expect(action.isModifier)
        #expect(action.output == nil)
    }

    @MainActor
    @Test("armed modifiers transform the next committed key", arguments: [
        (TerminalInputAccessoryAction.control, "c", "", [0x03]),
        (.alternate, "b", "", [0x1B, 0x62]),
        (.command, "a", "", [0x01]),
        (.shift, "a", "A", []),
    ] as [(TerminalInputAccessoryAction, String, String, [UInt8])])
    func modifierCombo(
        modifier: TerminalInputAccessoryAction,
        input: String,
        expectedText: String,
        expectedBytes: [UInt8]
    ) {
        let view = TerminalInputTextView()
        var committedText = ""
        var emittedData = Data()
        view.onText = { committedText.append($0) }
        view.onEscapeSequence = { emittedData.append($0) }

        view.simulateAccessoryActionForTesting(modifier)
        view.insertText(input)

        #expect(committedText == expectedText)
        #expect(emittedData == Data(expectedBytes))
    }

    @MainActor
    @Test("shift-tab emits back-tab")
    func shiftTab() {
        let view = TerminalInputTextView()
        var emittedData = Data()
        view.onEscapeSequence = { emittedData.append($0) }

        view.simulateAccessoryActionForTesting(.shift)
        view.simulateAccessoryActionForTesting(.tab)

        #expect(emittedData == Data([0x1B, 0x5B, 0x5A]))
    }
}
#endif
