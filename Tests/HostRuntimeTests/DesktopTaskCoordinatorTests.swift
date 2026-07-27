import ContextKernel
import Foundation
import HostRuntime
import MienContracts
import XCTest

final class DesktopTaskCoordinatorTests: XCTestCase {
  func testPreparationPinsInvocationWindowAndStartsMonotonicLedger() async throws {
    let now = Date()
    let snapshot = makeSnapshot(now: now)
    let coordinator = try DesktopTaskCoordinator()

    let prepared = try await coordinator.begin(
      intent: "Summarize this conversation",
      snapshot: snapshot,
      requestedScope: .conversation,
      now: now
    )

    XCTAssertEqual(prepared.targetLease.invocationSnapshotID, snapshot.id)
    XCTAssertEqual(prepared.targetLease.window.windowID, snapshot.window.windowID)
    XCTAssertEqual(prepared.capsule.targetLeaseID, prepared.targetLease.id)
    XCTAssertEqual(prepared.contextRequest.taskID, prepared.capsule.id)
    let events = try await coordinator.events(taskID: prepared.capsule.id)
    XCTAssertEqual(events.map(\.state), [.created, .targetLocked])
    XCTAssertEqual(events.map(\.sequence), [0, 1])
  }

  func testContextAttachmentUsesReservedManifestAndDeclaresDegradation() async throws {
    let now = Date()
    let coordinator = try DesktopTaskCoordinator()
    let prepared = try await coordinator.begin(
      intent: "Draft a reply",
      snapshot: makeSnapshot(now: now),
      requestedScope: .conversation,
      now: now
    )
    let artifact = ContextArtifact(
      taskID: prepared.capsule.id,
      targetLeaseID: prepared.targetLease.id,
      kind: .text,
      provider: .accessibility,
      providerVersion: "1",
      capturedAt: now,
      coherenceGroup: prepared.contextRequest.coherenceGroup,
      scope: .semanticRegion,
      mediaType: "text/plain",
      privateURI: URL(fileURLWithPath: "/tmp/context.txt"),
      contentDigest: String(repeating: "a", count: 64),
      sourceTrust: .hostObserved,
      sensitivity: .userContent,
      confidence: 1,
      complete: true,
      retention: ArtifactRetention(
        expiresAt: now.addingTimeInterval(30),
        deleteAfterTask: true,
        memoryEligible: false
      )
    )
    let resolution = ContextResolution(
      artifacts: [artifact],
      receipts: [],
      resolvedScope: .semanticRegion,
      omissions: [.longview: "screen recording permission unavailable"],
      exhaustedBudget: false
    )

    let manifest = try await coordinator.attachContext(
      resolution,
      to: prepared.capsule.id,
      remoteTransmissionAllowed: false,
      desktopRecoveryVerified: true,
      now: now
    )

    XCTAssertEqual(manifest.id, prepared.capsule.contextManifestID)
    XCTAssertEqual(manifest.resolvedScope, .semanticRegion)
    XCTAssertNotNil(manifest.omittedScopes[.conversation])
    let events = try await coordinator.events(taskID: prepared.capsule.id)
    XCTAssertEqual(events.last?.state, .degraded)
  }

  func testCancellationClosesReadOnlyTaskMonotonically() async throws {
    let now = Date()
    let coordinator = try DesktopTaskCoordinator()
    let prepared = try await coordinator.begin(
      intent: "Summarize this",
      snapshot: makeSnapshot(now: now),
      requestedScope: .semanticRegion,
      now: now
    )

    try await coordinator.cancel(
      taskID: prepared.capsule.id,
      reason: "user dismissed the overlay",
      now: now
    )
    try await coordinator.verifyCleanup(
      taskID: prepared.capsule.id,
      reason: "artifact deletion verified",
      now: now
    )

    let events = try await coordinator.events(taskID: prepared.capsule.id)
    XCTAssertEqual(events.map(\.state), [.created, .targetLocked, .cancelled, .cleanupVerified])
    XCTAssertEqual(events.map(\.sequence), [0, 1, 2, 3])
  }

  private func makeSnapshot(now: Date) -> InvocationSnapshot {
    InvocationSnapshot(
      invokedAt: now,
      window: WindowLease(
        processIdentifier: 42,
        windowID: 9,
        bundleIdentifier: "com.example.chat",
        frame: ScreenRect(x: 20, y: 30, width: 800, height: 600),
        capturedAt: now,
        expiresAt: now.addingTimeInterval(120),
        userInputEpoch: 7
      ),
      pointedElement: AXElementFingerprint(
        role: "AXTextArea",
        frame: ScreenRect(x: 100, y: 500, width: 500, height: 80)
      ),
      focusedElement: nil,
      selectedText: nil,
      environment: EnvironmentSnapshot(
        frontmostProcessIdentifier: 42,
        pointer: ScreenPoint(x: 200, y: 540),
        displayID: 1,
        userInputEpoch: 7
      )
    )
  }
}
