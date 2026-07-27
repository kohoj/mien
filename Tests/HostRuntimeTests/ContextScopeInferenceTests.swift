import Foundation
import HostRuntime
import MienContracts
import XCTest

final class ContextScopeInferenceTests: XCTestCase {
  func testExplicitHistoryIntentExpandsToBoundedHistoryWithoutUIControls() {
    let snapshot = makeSnapshot(selectedText: nil)
    XCTAssertEqual(
      ContextScopeInference().infer(
        intent: "总结完整聊天记录",
        snapshot: snapshot
      ),
      .boundedHistory
    )
  }

  func testSelectionAlwaysWinsOverBroadLanguage() {
    let snapshot = makeSnapshot(selectedText: "selected")
    XCTAssertEqual(
      ContextScopeInference().infer(
        intent: "总结完整聊天记录",
        snapshot: snapshot
      ),
      .selection
    )
  }

  private func makeSnapshot(selectedText: String?) -> InvocationSnapshot {
    let now = Date()
    return InvocationSnapshot(
      invokedAt: now,
      window: WindowLease(
        processIdentifier: 42,
        windowID: 9,
        bundleIdentifier: "com.example.chat",
        frame: ScreenRect(x: 0, y: 0, width: 800, height: 600),
        capturedAt: now,
        expiresAt: now.addingTimeInterval(30),
        userInputEpoch: 1
      ),
      pointedElement: AXElementFingerprint(role: "AXStaticText"),
      focusedElement: nil,
      selectedText: selectedText,
      environment: EnvironmentSnapshot(
        frontmostProcessIdentifier: 42,
        pointer: ScreenPoint(x: 1, y: 1),
        displayID: 1,
        userInputEpoch: 1
      )
    )
  }
}
