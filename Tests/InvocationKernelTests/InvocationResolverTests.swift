import Foundation
import InvocationKernel
import MienContracts
import XCTest

final class InvocationResolverTests: XCTestCase {
  func testDefaultInvocationLeaseSurvivesAgentPlanningAndSlowestCaptureRoute() throws {
    let now = Date()
    let resolver = InvocationResolver(
      windowProvider: StubWindowProvider(
        window: WindowSnapshot(
          processIdentifier: 99,
          windowID: 1234,
          bundleIdentifier: "com.example.target",
          frame: ScreenRect(x: 100, y: 100, width: 900, height: 700)
        ),
        displayID: 8
      ),
      semanticProvider: StubSemanticProvider(
        snapshot: SemanticSnapshot(
          pointedElement: AXElementFingerprint(role: "AXStaticText"),
          focusedElement: nil,
          selectedText: nil
        )
      ),
      ownProcessIdentifier: 10
    )

    let result = try resolver.resolve(
      pointer: ScreenPoint(x: 500, y: 300),
      frontmostProcessIdentifier: 99,
      userInputEpoch: 1,
      now: now
    )

    XCTAssertEqual(result.window.expiresAt, now.addingTimeInterval(45))
  }

  func testInvocationFreezesWindowPointerAndInputEpochBeforeOverlay() throws {
    let now = Date()
    let pointer = ScreenPoint(x: 500, y: 300)
    let window = WindowSnapshot(
      processIdentifier: 99,
      windowID: 1234,
      bundleIdentifier: "com.tencent.xinWeChat",
      frame: ScreenRect(x: 100, y: 100, width: 900, height: 700)
    )
    let semantic = SemanticSnapshot(
      pointedElement: AXElementFingerprint(role: "AXStaticText", label: "message"),
      focusedElement: AXElementFingerprint(role: "AXTextArea"),
      selectedText: nil
    )
    let resolver = InvocationResolver(
      windowProvider: StubWindowProvider(window: window, displayID: 8),
      semanticProvider: StubSemanticProvider(snapshot: semantic),
      ownProcessIdentifier: 10,
      leaseDuration: 5
    )

    let result = try resolver.resolve(
      pointer: pointer,
      frontmostProcessIdentifier: 99,
      userInputEpoch: 41,
      now: now
    )

    XCTAssertEqual(result.window.windowID, 1234)
    XCTAssertEqual(result.environment.pointer, pointer)
    XCTAssertEqual(result.environment.displayID, 8)
    XCTAssertEqual(result.environment.userInputEpoch, 41)
    XCTAssertEqual(result.pointedElement?.label, "message")
    XCTAssertEqual(result.window.expiresAt, now.addingTimeInterval(5))
  }

  /// Regression: the menu bar item sits above every application window, so a
  /// click there has no window under the cursor and the pointer path always
  /// fails. Resolving against the frontmost application must succeed and must
  /// leave `pointedElement` nil rather than inventing a target from the cursor.
  func testMenuBarInvocationResolvesFrontmostWindowWithoutAPointerTarget() throws {
    let now = Date()
    let window = WindowSnapshot(
      processIdentifier: 99,
      windowID: 1234,
      bundleIdentifier: "com.tencent.xinWeChat",
      frame: ScreenRect(x: 100, y: 100, width: 900, height: 700)
    )
    let semantic = SemanticSnapshot(
      pointedElement: AXElementFingerprint(role: "AXStaticText", label: "message"),
      focusedElement: AXElementFingerprint(role: "AXTextArea"),
      selectedText: nil
    )
    let resolver = InvocationResolver(
      windowProvider: StubWindowProvider(window: window, displayID: 8),
      semanticProvider: StubSemanticProvider(snapshot: semantic),
      ownProcessIdentifier: 10,
      leaseDuration: 5
    )

    let result = try resolver.resolveFrontmost(
      frontmostProcessIdentifier: 99,
      userInputEpoch: 7,
      now: now
    )

    XCTAssertEqual(result.window.windowID, 1234)
    XCTAssertNil(result.pointedElement)
    XCTAssertEqual(result.focusedElement?.role, "AXTextArea")
    XCTAssertEqual(result.environment.frontmostProcessIdentifier, 99)
    XCTAssertEqual(result.environment.userInputEpoch, 7)
    // The recorded pointer is the window centre, not wherever the cursor was.
    XCTAssertEqual(result.environment.pointer, ScreenPoint(x: 550, y: 450))
  }

  func testMenuBarInvocationRefusesToTargetTheHostItself() {
    let resolver = InvocationResolver(
      windowProvider: StubWindowProvider(
        window: WindowSnapshot(
          processIdentifier: 10,
          windowID: 1,
          bundleIdentifier: "io.github.kohoj.mien",
          frame: ScreenRect(x: 0, y: 0, width: 10, height: 10)
        ),
        displayID: 1
      ),
      semanticProvider: StubSemanticProvider(
        snapshot: SemanticSnapshot(pointedElement: nil, focusedElement: nil, selectedText: nil)
      ),
      ownProcessIdentifier: 10,
      leaseDuration: 5
    )

    XCTAssertThrowsError(
      try resolver.resolveFrontmost(frontmostProcessIdentifier: 10, userInputEpoch: 1)
    )
  }

  /// The host must never target itself, whichever route selected the window.
  /// The pointer route passes its own pid to `window(at:excluding:)`; the
  /// frontmost route refuses outright and falls through to the pointer.
  func testHostWindowIsExplicitlyExcludedFromWindowResolution() throws {
    let provider = RecordingWindowProvider()
    let resolver = InvocationResolver(
      windowProvider: provider,
      semanticProvider: StubSemanticProvider(
        snapshot: SemanticSnapshot(
          pointedElement: nil,
          focusedElement: nil,
          selectedText: nil
        )
      ),
      ownProcessIdentifier: 777
    )

    // Frontmost is the host itself, so resolution must fall through to the
    // pointer route rather than lease the host's own window.
    _ = try resolver.resolve(
      pointer: ScreenPoint(x: 1, y: 1),
      frontmostProcessIdentifier: 777,
      userInputEpoch: 0
    )

    XCTAssertEqual(provider.excludedProcessIdentifier, 777)
  }

  /// Regression: the target used to be whatever window sat under the cursor.
  /// The overlay opens near the pointer, so the pointer routinely lands on a
  /// window behind the one the user is working in — in one case Mien leased the
  /// terminal it was being developed in and summarised that as the user's chat.
  func testFrontmostApplicationWinsOverWhateverIsUnderThePointer() throws {
    let now = Date()
    let frontmost = WindowSnapshot(
      processIdentifier: 99,
      windowID: 1234,
      bundleIdentifier: "com.tencent.xinWeChat",
      frame: ScreenRect(x: 100, y: 100, width: 900, height: 700)
    )
    // What the cursor is over: a different application entirely.
    let underPointer = WindowSnapshot(
      processIdentifier: 55,
      windowID: 4321,
      bundleIdentifier: "dev.warp.Warp-Stable",
      frame: ScreenRect(x: 4_000, y: 4_000, width: 800, height: 600)
    )
    let resolver = InvocationResolver(
      windowProvider: StubWindowProvider(
        window: frontmost,
        displayID: 8,
        pointerWindow: underPointer
      ),
      semanticProvider: StubSemanticProvider(
        snapshot: SemanticSnapshot(
          pointedElement: nil,
          focusedElement: AXElementFingerprint(role: "AXTextArea"),
          selectedText: nil
        )
      ),
      ownProcessIdentifier: 10,
      leaseDuration: 5
    )

    // Pointer far outside the frontmost window, as when the overlay sits over
    // another application.
    let result = try resolver.resolve(
      pointer: ScreenPoint(x: 5_000, y: 5_000),
      frontmostProcessIdentifier: 99,
      userInputEpoch: 3,
      now: now
    )

    XCTAssertEqual(result.window.windowID, 1234)
    XCTAssertEqual(result.window.bundleIdentifier, "com.tencent.xinWeChat")
  }

  func testFollowUpRenewsOnlyTheExactOriginalWindowIdentity() throws {
    let firstDate = Date(timeIntervalSince1970: 100)
    let followUpDate = Date(timeIntervalSince1970: 200)
    let originalWindow = WindowSnapshot(
      processIdentifier: 99,
      windowID: 1234,
      bundleIdentifier: "com.tencent.xinWeChat",
      frame: ScreenRect(x: 100, y: 100, width: 900, height: 700)
    )
    let originalResolver = InvocationResolver(
      windowProvider: StubWindowProvider(window: originalWindow, displayID: 8),
      semanticProvider: StubSemanticProvider(
        snapshot: SemanticSnapshot(pointedElement: nil, focusedElement: nil, selectedText: nil)
      ),
      ownProcessIdentifier: 10,
      leaseDuration: 5
    )
    let snapshot = try originalResolver.resolve(
      pointer: ScreenPoint(x: 500, y: 300),
      frontmostProcessIdentifier: 99,
      userInputEpoch: 9,
      now: firstDate
    )
    let movedWindow = WindowSnapshot(
      processIdentifier: 99,
      windowID: 1234,
      bundleIdentifier: "com.tencent.xinWeChat",
      frame: ScreenRect(x: 120, y: 110, width: 920, height: 720)
    )
    let followUpResolver = InvocationResolver(
      windowProvider: StubWindowProvider(window: movedWindow, displayID: 8),
      semanticProvider: StubSemanticProvider(
        snapshot: SemanticSnapshot(
          pointedElement: AXElementFingerprint(role: "AXStaticText"),
          focusedElement: AXElementFingerprint(role: "AXTextArea"),
          selectedText: "new selection"
        )
      ),
      ownProcessIdentifier: 10,
      leaseDuration: 5
    )

    let renewed = try followUpResolver.renew(
      snapshot,
      userInputEpoch: 10,
      now: followUpDate
    )

    XCTAssertEqual(renewed.window.windowID, snapshot.window.windowID)
    XCTAssertEqual(renewed.window.frame, movedWindow.frame)
    XCTAssertEqual(renewed.window.capturedAt, followUpDate)
    XCTAssertEqual(renewed.window.expiresAt, followUpDate.addingTimeInterval(5))
    XCTAssertEqual(renewed.window.userInputEpoch, 10)
    XCTAssertEqual(renewed.environment.userInputEpoch, 10)
    XCTAssertEqual(renewed.selectedText, "new selection")

    let replacementResolver = InvocationResolver(
      windowProvider: StubWindowProvider(
        window: WindowSnapshot(
          processIdentifier: 99,
          windowID: 9999,
          bundleIdentifier: "com.tencent.xinWeChat",
          frame: movedWindow.frame
        ),
        displayID: 8
      ),
      semanticProvider: StubSemanticProvider(
        snapshot: SemanticSnapshot(pointedElement: nil, focusedElement: nil, selectedText: nil)
      ),
      ownProcessIdentifier: 10,
      leaseDuration: 5
    )
    XCTAssertThrowsError(try replacementResolver.renew(snapshot, now: followUpDate)) { error in
      XCTAssertEqual(error as? InvocationResolutionError, .targetChanged)
    }
  }
}

private struct StubWindowProvider: WindowSnapshotProviding {
  let window: WindowSnapshot
  let displayID: UInt32
  /// Distinct from `window` so a test can tell which route was taken.
  var pointerWindow: WindowSnapshot?

  func window(at point: ScreenPoint, excluding processIdentifier: Int32) throws -> WindowSnapshot {
    pointerWindow ?? window
  }

  func frontmostWindow(of processIdentifier: Int32) throws -> WindowSnapshot { window }

  func displayID(at point: ScreenPoint) throws -> UInt32 { displayID }
}

private struct StubSemanticProvider: SemanticSnapshotProviding {
  let snapshot: SemanticSnapshot

  func snapshot(at point: ScreenPoint, processIdentifier: Int32) -> SemanticSnapshot { snapshot }
}

private final class RecordingWindowProvider: WindowSnapshotProviding, @unchecked Sendable {
  private(set) var excludedProcessIdentifier: Int32?

  func window(at point: ScreenPoint, excluding processIdentifier: Int32) throws -> WindowSnapshot {
    excludedProcessIdentifier = processIdentifier
    return WindowSnapshot(
      processIdentifier: 42,
      windowID: 9,
      bundleIdentifier: "com.example.app",
      frame: ScreenRect(x: 0, y: 0, width: 100, height: 100)
    )
  }

  func frontmostWindow(of processIdentifier: Int32) throws -> WindowSnapshot {
    WindowSnapshot(
      processIdentifier: processIdentifier,
      windowID: 9,
      bundleIdentifier: "com.example.app",
      frame: ScreenRect(x: 0, y: 0, width: 100, height: 100)
    )
  }

  func displayID(at point: ScreenPoint) throws -> UInt32 { 1 }
}
