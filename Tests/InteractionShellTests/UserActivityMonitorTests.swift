import AppKit
import CoreGraphics
import XCTest

@testable import InteractionShell

@MainActor
final class UserActivityMonitorTests: XCTestCase {
  func testLocalInputInOwnedWindowDoesNotTriggerTakeover() throws {
    let windowNumber = 41

    for type in monitoredLocalEventTypes {
      let event = try makeEvent(type: type, windowNumber: windowNumber)
      XCTAssertFalse(
        UserActivityMonitor.shouldTriggerTakeover(
          for: event,
          origin: .local,
          ownedWindowNumbers: [event.windowNumber]
        ),
        "\(type) must remain in the Mien responder chain"
      )
    }
  }

  func testLocalInputOutsideOwnedWindowTriggersTakeover() throws {
    let event = try makeEvent(type: .leftMouseDown, windowNumber: 84)

    XCTAssertTrue(
      UserActivityMonitor.shouldTriggerTakeover(
        for: event,
        origin: .local,
        ownedWindowNumbers: [41]
      )
    )
  }

  func testGlobalInputTriggersTakeoverEvenWhenWindowNumberMatches() throws {
    let event = try makeEvent(type: .keyDown, windowNumber: 41)

    XCTAssertTrue(
      UserActivityMonitor.shouldTriggerTakeover(
        for: event,
        origin: .global,
        ownedWindowNumbers: [41]
      )
    )
  }

  func testLongviewGeneratedInputNeverTriggersTakeover() throws {
    let source = CGEventSource(stateID: .privateState)
    let cgEvent = try XCTUnwrap(
      CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
    )
    cgEvent.setIntegerValueField(
      .eventSourceUserData,
      value: 0x4846_5343_524F_4C4C
    )
    let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))

    XCTAssertFalse(
      UserActivityMonitor.shouldTriggerTakeover(
        for: event,
        origin: .global,
        ownedWindowNumbers: []
      )
    )
  }

  private var monitoredLocalEventTypes: [NSEvent.EventType] {
    [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
  }

  private func makeEvent(type: NSEvent.EventType, windowNumber: Int) throws -> NSEvent {
    switch type {
    case .keyDown:
      return try XCTUnwrap(
        NSEvent.keyEvent(
          with: type,
          location: .zero,
          modifierFlags: [],
          timestamp: 0,
          windowNumber: windowNumber,
          context: nil,
          characters: "a",
          charactersIgnoringModifiers: "a",
          isARepeat: false,
          keyCode: 0
        )
      )
    case .scrollWheel:
      let cgEvent = try XCTUnwrap(
        CGEvent(
          scrollWheelEvent2Source: nil,
          units: .pixel,
          wheelCount: 1,
          wheel1: 1,
          wheel2: 0,
          wheel3: 0
        )
      )
      return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    default:
      return try XCTUnwrap(
        NSEvent.mouseEvent(
          with: type,
          location: .zero,
          modifierFlags: [],
          timestamp: 0,
          windowNumber: windowNumber,
          context: nil,
          eventNumber: 1,
          clickCount: 1,
          pressure: 1
        )
      )
    }
  }
}
