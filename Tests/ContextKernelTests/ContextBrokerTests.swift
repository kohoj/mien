import ContextKernel
import Foundation
import MienContracts
import XCTest

final class ContextBrokerTests: XCTestCase {
  func testBrokerUsesMinimumProviderLadderAndStopsAtRequestedScope() async throws {
    let now = Date()
    let taskID = UUID()
    let target = makeTarget(now: now)
    let coherenceGroup = UUID()
    let calls = CallRecorder()
    let screen = StubProvider(
      kind: .screenCapture,
      maximumScope: .window,
      artifacts: [
        makeArtifact(
          now: now,
          taskID: taskID,
          targetLeaseID: target.id,
          provider: .screenCapture,
          scope: .window,
          coherenceGroup: coherenceGroup
        )
      ],
      calls: calls
    )
    let accessibility = StubProvider(
      kind: .accessibility,
      maximumScope: .conversation,
      artifacts: [
        makeArtifact(
          now: now,
          taskID: taskID,
          targetLeaseID: target.id,
          provider: .accessibility,
          scope: .conversation,
          coherenceGroup: coherenceGroup
        )
      ],
      calls: calls
    )
    let broker = ContextBroker(providers: [screen, accessibility])

    let result = try await broker.resolve(
      ContextCaptureRequest(
        taskID: taskID,
        target: target,
        requestedScope: .conversation,
        budget: ContextBudget(
          maximumArtifacts: 4,
          maximumBytes: 1_000_000,
          maximumTextCharacters: 20_000,
          deadline: now.addingTimeInterval(30)
        ),
        coherenceGroup: coherenceGroup
      ), now: now)

    let providerCalls = await calls.values()
    XCTAssertEqual(result.resolvedScope, .conversation)
    XCTAssertEqual(providerCalls, [.accessibility])
  }

  func testUnavailableSemanticProviderFallsBackToPixels() async throws {
    let now = Date()
    let taskID = UUID()
    let target = makeTarget(now: now)
    let coherenceGroup = UUID()
    let calls = CallRecorder()
    let accessibility = StubProvider(
      kind: .accessibility,
      maximumScope: .conversation,
      artifacts: [],
      calls: calls,
      available: false
    )
    let screen = StubProvider(
      kind: .screenCapture,
      maximumScope: .window,
      artifacts: [
        makeArtifact(
          now: now,
          taskID: taskID,
          targetLeaseID: target.id,
          provider: .screenCapture,
          scope: .window,
          coherenceGroup: coherenceGroup
        )
      ],
      calls: calls
    )
    let broker = ContextBroker(providers: [screen, accessibility])

    let result = try await broker.resolve(
      ContextCaptureRequest(
        taskID: taskID,
        target: target,
        requestedScope: .window,
        budget: ContextBudget(
          maximumArtifacts: 4,
          maximumBytes: 1_000_000,
          maximumTextCharacters: 20_000,
          deadline: now.addingTimeInterval(30)
        ),
        coherenceGroup: coherenceGroup
      ), now: now)

    let providerCalls = await calls.values()
    XCTAssertEqual(result.resolvedScope, .window)
    XCTAssertNotNil(result.omissions[.accessibility])
    XCTAssertEqual(providerCalls, [.screenCapture])
  }

  func testBrokerRejectsArtifactsThatExceedTheByteBudget() async throws {
    let now = Date()
    let taskID = UUID()
    let target = makeTarget(now: now)
    let coherenceGroup = UUID()
    let provider = StubProvider(
      kind: .accessibility,
      maximumScope: .semanticRegion,
      artifacts: [
        makeArtifact(
          now: now,
          taskID: taskID,
          targetLeaseID: target.id,
          provider: .accessibility,
          scope: .semanticRegion,
          byteCount: 2_000,
          coherenceGroup: coherenceGroup
        )
      ],
      calls: CallRecorder()
    )
    let result = try await ContextBroker(providers: [provider]).resolve(
      ContextCaptureRequest(
        taskID: taskID,
        target: target,
        requestedScope: .semanticRegion,
        budget: ContextBudget(
          maximumArtifacts: 1,
          maximumBytes: 1_000,
          maximumTextCharacters: 1_000,
          deadline: now.addingTimeInterval(1)
        ),
        coherenceGroup: coherenceGroup
      ), now: now)

    XCTAssertTrue(result.artifacts.isEmpty)
    XCTAssertNotNil(result.omissions[.accessibility])
  }

  func testBrokerCancelsAProviderAtTheHardDeadline() async throws {
    let now = Date()
    let target = makeTarget(now: now)
    let clock = ContinuousClock()
    let start = clock.now

    let result = try await ContextBroker(providers: [SlowProvider()]).resolve(
      ContextCaptureRequest(
        taskID: UUID(),
        target: target,
        requestedScope: .window,
        budget: ContextBudget(
          maximumArtifacts: 1,
          maximumBytes: 1_000,
          maximumTextCharacters: 1_000,
          deadline: now.addingTimeInterval(0.05)
        )
      ), now: now)

    XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(500))
    XCTAssertTrue(result.artifacts.isEmpty)
    XCTAssertNotNil(result.omissions[.screenCapture])
  }

  private func makeTarget(now: Date) -> TargetLease {
    let window = WindowLease(
      processIdentifier: 42,
      windowID: 7,
      bundleIdentifier: "com.example.app",
      frame: ScreenRect(x: 0, y: 0, width: 800, height: 600),
      capturedAt: now,
      expiresAt: now.addingTimeInterval(30),
      userInputEpoch: 1
    )
    return TargetLease(
      invocationSnapshotID: UUID(),
      window: window,
      semanticTarget: nil,
      issuedAt: now,
      expiresAt: now.addingTimeInterval(20)
    )
  }

  private func makeArtifact(
    now: Date,
    taskID: UUID,
    targetLeaseID: UUID,
    provider: ContextProviderKind,
    scope: ContextScope,
    byteCount: Int = 0,
    coherenceGroup: UUID
  ) -> ContextArtifact {
    ContextArtifact(
      taskID: taskID,
      targetLeaseID: targetLeaseID,
      kind: provider == .screenCapture ? .image : .text,
      provider: provider,
      providerVersion: "1",
      capturedAt: now,
      coherenceGroup: coherenceGroup,
      scope: scope,
      mediaType: provider == .screenCapture ? "image/png" : "text/plain",
      privateURI: URL(fileURLWithPath: "/tmp/context"),
      byteCount: byteCount,
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
}

private struct SlowProvider: ContextProvider {
  let kind: ContextProviderKind = .screenCapture

  func probe(target: TargetLease) async -> ProviderCapability {
    ProviderCapability(
      available: true,
      maximumScope: .window,
      estimatedLatencyMilliseconds: 10_000,
      reason: "test"
    )
  }

  func capture(_ request: ContextCaptureRequest) async throws -> ContextCaptureOutcome {
    try await Task.sleep(for: .seconds(10))
    return ContextCaptureOutcome(artifacts: [])
  }
}

private actor CallRecorder {
  private var storage: [ContextProviderKind] = []

  func record(_ kind: ContextProviderKind) { storage.append(kind) }
  func values() -> [ContextProviderKind] { storage }
}

private struct StubProvider: ContextProvider {
  let kind: ContextProviderKind
  let maximumScope: ContextScope
  let artifacts: [ContextArtifact]
  let calls: CallRecorder
  let available: Bool

  init(
    kind: ContextProviderKind,
    maximumScope: ContextScope,
    artifacts: [ContextArtifact],
    calls: CallRecorder,
    available: Bool = true
  ) {
    self.kind = kind
    self.maximumScope = maximumScope
    self.artifacts = artifacts
    self.calls = calls
    self.available = available
  }

  func probe(target: TargetLease) async -> ProviderCapability {
    ProviderCapability(
      available: available,
      maximumScope: maximumScope,
      estimatedLatencyMilliseconds: 20,
      reason: available ? "ready" : "unavailable"
    )
  }

  func capture(_ request: ContextCaptureRequest) async throws -> ContextCaptureOutcome {
    await calls.record(kind)
    return ContextCaptureOutcome(artifacts: artifacts)
  }
}
