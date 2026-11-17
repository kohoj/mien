import AppKit
import InvocationKernel
import MienContracts
import XCTest

@testable import InteractionShell

@MainActor
final class AuthenticationRecoveryTests: XCTestCase {
  func testLoginCompletionRenewsExpiredTargetThroughNormalSubmission() async throws {
    _ = NSApplication.shared
    let window = WindowSnapshot(
      processIdentifier: 99,
      windowID: 1234,
      bundleIdentifier: "com.apple.TextEdit",
      frame: ScreenRect(x: 100, y: 100, width: 800, height: 600)
    )
    let resolver = InvocationResolver(
      windowProvider: RecoveryWindowProvider(window: window),
      semanticProvider: RecoverySemanticProvider(),
      ownProcessIdentifier: 10
    )
    let expired = try resolver.resolve(
      pointer: ScreenPoint(x: 200, y: 200),
      frontmostProcessIdentifier: 99,
      userInputEpoch: 0,
      now: Date().addingTimeInterval(-120)
    )
    XCTAssertLessThan(expired.window.expiresAt, Date())

    let composer = ComposerViewController()
    let overlay = OverlayCoordinator(composerController: composer)
    let interaction = InteractionController(resolver: resolver, overlay: overlay)
    defer { interaction.stop() }
    try overlay.show(snapshot: expired)
    let input = "  请总结\n这段内容  "
    composer.beginRunning(submittedText: input)
    interaction.showActionPrompt(status: "重新连接", action: .loginCodex)
    composer.settleMotionForRendering()

    let resumed = expectation(description: "original input with fresh exact target")
    interaction.onSubmit = { intent, snapshot in
      XCTAssertEqual(intent, input)
      XCTAssertEqual(snapshot.window.windowID, expired.window.windowID)
      XCTAssertEqual(snapshot.window.processIdentifier, expired.window.processIdentifier)
      XCTAssertNotEqual(snapshot.id, expired.id)
      XCTAssertGreaterThan(snapshot.window.expiresAt, Date())
      XCTAssertGreaterThan(snapshot.environment.userInputEpoch, expired.environment.userInputEpoch)
      XCTAssertEqual(snapshot.selectedText, "fresh selection")
      resumed.fulfill()
    }
    interaction.resumeAfterAuthentication()
    await fulfillment(of: [resumed], timeout: 2)
    XCTAssertEqual(composer.submittedTurnCount, 1)
  }
}

private struct RecoveryWindowProvider: WindowSnapshotProviding {
  let window: WindowSnapshot
  func window(at point: ScreenPoint, excluding processIdentifier: Int32) throws -> WindowSnapshot {
    window
  }
  func frontmostWindow(of processIdentifier: Int32) throws -> WindowSnapshot { window }
  func displayID(at point: ScreenPoint) throws -> UInt32 { CGMainDisplayID() }
}

private struct RecoverySemanticProvider: SemanticSnapshotProviding {
  func snapshot(at point: ScreenPoint, processIdentifier: Int32) -> SemanticSnapshot {
    SemanticSnapshot(pointedElement: nil, focusedElement: nil, selectedText: "fresh selection")
  }
}
