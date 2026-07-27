import Carbon
import InteractionShell
import XCTest

final class GlobalShortcutRegistrarTests: XCTestCase {
  func testDefaultShortcutMatchesTheDocumentedControlOptionSpaceChord() {
    XCTAssertEqual(
      GlobalShortcutRegistrar.Shortcut.default,
      GlobalShortcutRegistrar.Shortcut(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey)
      )
    )
  }
}
