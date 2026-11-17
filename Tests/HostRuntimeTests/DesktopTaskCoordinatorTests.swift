import ContextKernel
import Foundation
import HostRuntime
import MienContracts
import XCTest

final class DesktopTaskCoordinatorTests: XCTestCase {
  func testAgentCanExplicitlyAdvanceWithoutCreatingContext() async throws {
    let now = Date()
    let coordinator = try DesktopTaskCoordinator()
    let locked = try await coordinator.lockTarget(
      intent: "Hello",
      snapshot: makeSnapshot(now: now),
      now: now
    )

    try await coordinator.markContextPlanning(taskID: locked.capsule.id, now: now)
    try await coordinator.markAgentRunningWithoutContext(taskID: locked.capsule.id, now: now)
    try await coordinator.completeReadOnly(
      taskID: locked.capsule.id,
      succeeded: true,
      reason: "typed outcome validated",
      now: now
    )

    let events = try await coordinator.events(taskID: locked.capsule.id)
    XCTAssertEqual(
      events.map(\.state),
      [.created, .targetLocked, .contextPlanning, .agentRunning, .succeeded]
    )
    XCTAssertEqual(events[3].reason, "Agent explicitly selected no external context")
    XCTAssertTrue(events.allSatisfy { $0.artifactIDs.isEmpty })
  }

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
    XCTAssertEqual(events.map(\.state), [.created, .targetLocked, .contextPlanning])
    XCTAssertEqual(events.map(\.sequence), [0, 1, 2])
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
    XCTAssertEqual(
      events.map(\.state),
      [.created, .targetLocked, .contextPlanning, .cancelled, .cleanupVerified]
    )
    XCTAssertEqual(events.map(\.sequence), [0, 1, 2, 3, 4])
  }

  /// Regression: with the pointer resting on the menu bar, taking
  /// `pointedElement` unconditionally made the menu bar the target, so the
  /// agent received menu titles instead of the document behind them. Chrome
  /// must yield to keyboard focus.
  func testPointerOnWindowChromeFallsBackToKeyboardFocus() async throws {
    let now = Date()
    let coordinator = try DesktopTaskCoordinator()
    let webArea = AXElementFingerprint(
      role: "AXWebArea",
      frame: ScreenRect(x: 20, y: 60, width: 780, height: 540)
    )
    let snapshot = makeSnapshot(
      now: now,
      pointedElement: AXElementFingerprint(
        role: "AXMenuBar",
        frame: ScreenRect(x: 0, y: 0, width: 1920, height: 30)
      ),
      focusedElement: webArea
    )

    let prepared = try await coordinator.begin(
      intent: "这个网站干啥的",
      snapshot: snapshot,
      requestedScope: .conversation,
      now: now
    )

    XCTAssertEqual(prepared.targetLease.semanticTarget?.role, "AXWebArea")
  }

  func testPointerOnContentStillWinsOverKeyboardFocus() async throws {
    let now = Date()
    let coordinator = try DesktopTaskCoordinator()
    let snapshot = makeSnapshot(
      now: now,
      pointedElement: AXElementFingerprint(
        role: "AXStaticText",
        frame: ScreenRect(x: 100, y: 200, width: 200, height: 20)
      ),
      focusedElement: AXElementFingerprint(role: "AXTextArea")
    )

    let prepared = try await coordinator.begin(
      intent: "总结",
      snapshot: snapshot,
      requestedScope: .conversation,
      now: now
    )

    XCTAssertEqual(prepared.targetLease.semanticTarget?.role, "AXStaticText")
  }

  /// Applications like WeChat expose no accessibility text, so the host falls
  /// back to a pixel capture, which Longview only produces at
  /// `.boundedHistory`. Sealing the manifest against the original
  /// `.conversation` request would fail the lineage check and discard the only
  /// artifact the task managed to acquire.
  func testManifestCanBeSealedAgainstAWidenedFallbackScope() async throws {
    let now = Date()
    let coordinator = try DesktopTaskCoordinator()
    let prepared = try await coordinator.begin(
      intent: "群里聊了啥",
      snapshot: makeSnapshot(now: now),
      requestedScope: .conversation,
      now: now
    )
    let artifact = makeFallbackArtifact(
      now: now,
      taskID: prepared.capsule.id,
      targetLeaseID: prepared.targetLease.id,
      coherenceGroup: prepared.contextRequest.coherenceGroup
    )

    let manifest = try await coordinator.attachContext(
      ContextResolution(
        artifacts: [artifact],
        resolvedScope: .boundedHistory,
        omissions: [:],
        exhaustedBudget: false
      ),
      to: prepared.capsule.id,
      remoteTransmissionAllowed: true,
      desktopRecoveryVerified: true,
      pursuedScope: .boundedHistory,
      now: now
    )

    XCTAssertEqual(manifest.requestedScope, .boundedHistory)
    XCTAssertEqual(manifest.resolvedScope, .boundedHistory)
    XCTAssertEqual(manifest.artifacts.count, 1)
  }

  /// Agent planning happens before evidence acquisition, so the immutable
  /// target has to survive the planning turn and the longest capture route.
  func testConfigurationRejectsALeaseTooShortForPlanningAndCapture() {
    XCTAssertThrowsError(
      try DesktopTaskCoordinator(
        configuration: DesktopTaskConfiguration(
          targetLeaseDuration: 24,
          contextPlanningDeadline: 7,
          contextDeadline: 3,
          boundedHistoryContextDeadline: 18
        )
      )
    )
    XCTAssertNoThrow(
      try DesktopTaskCoordinator(
        configuration: DesktopTaskConfiguration(
          targetLeaseDuration: 25,
          contextPlanningDeadline: 7,
          contextDeadline: 3,
          boundedHistoryContextDeadline: 18
        )
      )
    )
  }

  func testDefaultLeaseLeavesBoundedSlackAroundAgentPlanningAndVisualHistory() {
    let configuration = DesktopTaskConfiguration()

    XCTAssertEqual(configuration.contextPlanningDeadline, 20)
    XCTAssertEqual(configuration.boundedHistoryContextDeadline, 18)
    XCTAssertGreaterThanOrEqual(
      configuration.targetLeaseDuration,
      configuration.contextPlanningDeadline
        + configuration.boundedHistoryContextDeadline
        + 5
    )
  }

  private func makeFallbackArtifact(
    now: Date,
    taskID: UUID,
    targetLeaseID: UUID,
    coherenceGroup: UUID
  ) -> ContextArtifact {
    ContextArtifact(
      taskID: taskID,
      targetLeaseID: targetLeaseID,
      kind: .image,
      provider: .longview,
      providerVersion: "schema-v2",
      capturedAt: now,
      coherenceGroup: coherenceGroup,
      scope: .boundedHistory,
      mediaType: "image/png",
      privateURI: URL(fileURLWithPath: "/tmp/context.png"),
      byteCount: 16,
      contentDigest: String(repeating: "a", count: 64),
      sourceTrust: .untrustedContent,
      sensitivity: .userContent,
      confidence: 1,
      complete: true,
      retention: ArtifactRetention(
        expiresAt: now.addingTimeInterval(30),
        deleteAfterTask: true,
        memoryEligible: false
      )
    )
  }

  private func makeSnapshot(
    now: Date,
    pointedElement: AXElementFingerprint?,
    focusedElement: AXElementFingerprint?
  ) -> InvocationSnapshot {
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
      pointedElement: pointedElement,
      focusedElement: focusedElement,
      selectedText: nil,
      environment: EnvironmentSnapshot(
        frontmostProcessIdentifier: 42,
        pointer: ScreenPoint(x: 200, y: 540),
        displayID: 1,
        userInputEpoch: 7
      )
    )
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
