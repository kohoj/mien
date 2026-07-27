import ArtifactStore
import ContextKernel
import Foundation
import MienContracts
import ProviderAdapters
import XCTest

final class DesktopContextProvidersTests: XCTestCase {
  func testSelectionProviderPersistsBoundedPrivateArtifact() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PrivateArtifactStore(rootURL: root)
    let now = Date()
    let target = makeTarget(now: now)
    let snapshot = InvocationSnapshot(
      invokedAt: now,
      window: target.window,
      pointedElement: target.semanticTarget,
      focusedElement: nil,
      selectedText: "A selected message that is longer than the budget",
      environment: EnvironmentSnapshot(
        frontmostProcessIdentifier: 42,
        pointer: ScreenPoint(x: 10, y: 10),
        displayID: 1,
        userInputEpoch: 1
      )
    )
    let provider = SelectionContextProvider(snapshot: snapshot, store: store)
    let request = ContextCaptureRequest(
      taskID: UUID(),
      target: target,
      requestedScope: .selection,
      budget: ContextBudget(
        maximumArtifacts: 1,
        maximumBytes: 1_024,
        maximumTextCharacters: 10,
        deadline: now.addingTimeInterval(3)
      )
    )

    let outcome = try await provider.capture(request)

    let artifact = try XCTUnwrap(outcome.artifacts.first)
    XCTAssertEqual(artifact.scope, .selection)
    XCTAssertFalse(artifact.complete)
    XCTAssertEqual(try String(contentsOf: artifact.privateURI, encoding: .utf8), "A selected")
  }

  private func makeTarget(now: Date) -> TargetLease {
    TargetLease(
      invocationSnapshotID: UUID(),
      window: WindowLease(
        processIdentifier: 42,
        windowID: 9,
        bundleIdentifier: "com.example.chat",
        frame: ScreenRect(x: 0, y: 0, width: 800, height: 600),
        capturedAt: now,
        expiresAt: now.addingTimeInterval(30),
        userInputEpoch: 1
      ),
      semanticTarget: AXElementFingerprint(
        role: "AXStaticText",
        frame: ScreenRect(x: 10, y: 10, width: 100, height: 20)
      ),
      issuedAt: now,
      expiresAt: now.addingTimeInterval(20)
    )
  }
}
