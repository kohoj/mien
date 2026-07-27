import Foundation
import InvocationKernel
import MienContracts
import XCTest

final class InvocationResolverTests: XCTestCase {
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

    _ = try resolver.resolve(
      pointer: ScreenPoint(x: 1, y: 1),
      frontmostProcessIdentifier: 42,
      userInputEpoch: 0
    )

    XCTAssertEqual(provider.excludedProcessIdentifier, 777)
  }
}

private struct StubWindowProvider: WindowSnapshotProviding {
  let window: WindowSnapshot
  let displayID: UInt32

  func window(at point: ScreenPoint, excluding processIdentifier: Int32) throws -> WindowSnapshot {
    window
  }

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

  func displayID(at point: ScreenPoint) throws -> UInt32 { 1 }
}
