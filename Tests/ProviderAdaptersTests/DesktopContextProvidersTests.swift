import ArtifactStore
import ContextKernel
import Foundation
import MienContracts
import XCTest

@testable import ProviderAdapters

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

  /// A conversation target is often the list or scroll area itself, not a child
  /// of one — Finder's file list and a browser's web area both behave this way.
  /// Reading only `ancestorRoles` would miss those and silently narrow the
  /// resolved scope to `.semanticRegion`.
  func testConversationCapabilityCountsTheTargetsOwnRole() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = AccessibilityContextProvider(store: try PrivateArtifactStore(rootURL: root))
    let now = Date()

    for role in ["AXScrollArea", "AXList", "AXTable"] {
      let capability = await provider.probe(
        target: makeTarget(now: now, semanticRole: role, ancestorRoles: [])
      )
      XCTAssertEqual(capability.maximumScope, .conversation, "own role \(role)")
    }

    let viaAncestor = await provider.probe(
      target: makeTarget(now: now, semanticRole: "AXStaticText", ancestorRoles: ["AXList"])
    )
    XCTAssertEqual(viaAncestor.maximumScope, .conversation)

    let neither = await provider.probe(
      target: makeTarget(now: now, semanticRole: "AXStaticText", ancestorRoles: ["AXGroup"])
    )
    XCTAssertEqual(neither.maximumScope, .semanticRegion)
  }

  func testAccessibilityExtractionReportsOnlyTheRootItActuallyProved() {
    XCTAssertEqual(
      AccessibilityContextProvider.resolvedScope(
        for: .pointedElement,
        foundConversationRoot: false
      ),
      .pointedElement
    )
    XCTAssertEqual(
      AccessibilityContextProvider.resolvedScope(
        for: .semanticRegion,
        foundConversationRoot: false
      ),
      .pointedElement
    )
    XCTAssertEqual(
      AccessibilityContextProvider.resolvedScope(
        for: .conversation,
        foundConversationRoot: true
      ),
      .conversation
    )
  }

  private func makeTarget(
    now: Date,
    semanticRole: String,
    ancestorRoles: [String]
  ) -> TargetLease {
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
        role: semanticRole,
        frame: ScreenRect(x: 10, y: 10, width: 100, height: 20),
        ancestorRoles: ancestorRoles
      ),
      issuedAt: now,
      expiresAt: now.addingTimeInterval(20)
    )
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
