import Foundation
import MienContracts
import XCTest

final class ContractValidationTests: XCTestCase {
  func testWindowLeaseRequiresStableWindowServerIdentity() {
    let now = Date()
    let lease = WindowLease(
      processIdentifier: 42,
      windowID: 0,
      bundleIdentifier: "com.example.app",
      frame: ScreenRect(x: 10, y: 20, width: 800, height: 600),
      capturedAt: now,
      expiresAt: now.addingTimeInterval(30),
      userInputEpoch: 1
    )

    XCTAssertThrowsError(try lease.validate(now: now)) { error in
      XCTAssertEqual(error as? ContractValidationError, .invalid("window.windowID"))
    }
  }

  func testTargetLeaseRejectsProtectedContent() {
    let now = Date()
    let window = makeWindowLease(now: now)
    let lease = TargetLease(
      invocationSnapshotID: UUID(),
      window: window,
      semanticTarget: AXElementFingerprint(
        role: "AXSecureTextField",
        protectedContent: true
      ),
      issuedAt: now,
      expiresAt: now.addingTimeInterval(10)
    )

    XCTAssertThrowsError(try lease.validate(now: now)) { error in
      XCTAssertEqual(
        error as? ContractValidationError,
        .unauthorized("protected semantic target")
      )
    }
  }

  func testManifestRejectsArtifactThatEscapesTargetLease() throws {
    let now = Date()
    let taskID = UUID()
    let leaseID = UUID()
    let artifact = makeArtifact(
      now: now,
      taskID: taskID,
      targetLeaseID: UUID()
    )
    let manifest = ContextManifest(
      taskID: taskID,
      targetLeaseID: leaseID,
      requestedScope: .conversation,
      resolvedScope: .conversation,
      artifacts: [artifact],
      omittedScopes: [:],
      budget: ContextBudget(
        maximumArtifacts: 4,
        maximumBytes: 1_000_000,
        maximumTextCharacters: 20_000,
        deadline: now.addingTimeInterval(30)
      ),
      remoteTransmissionAllowed: true,
      coherent: true,
      digest: String(repeating: "b", count: 64)
    )

    XCTAssertThrowsError(try manifest.validate(now: now)) { error in
      XCTAssertEqual(
        error as? ContractValidationError,
        .inconsistent("artifact escaped task or target lease")
      )
    }
  }

  func testOmissionCannotAuthorizeAnUnrelatedScopeExpansion() {
    let now = Date()
    let taskID = UUID()
    let leaseID = UUID()
    let artifact = makeArtifact(now: now, taskID: taskID, targetLeaseID: leaseID)
    let expandedArtifact = ContextArtifact(
      id: artifact.id,
      taskID: artifact.taskID,
      targetLeaseID: artifact.targetLeaseID,
      kind: artifact.kind,
      provider: artifact.provider,
      providerVersion: artifact.providerVersion,
      capturedAt: artifact.capturedAt,
      coherenceGroup: artifact.coherenceGroup,
      scope: .window,
      mediaType: artifact.mediaType,
      privateURI: artifact.privateURI,
      byteCount: artifact.byteCount,
      contentDigest: artifact.contentDigest,
      sourceTrust: artifact.sourceTrust,
      sensitivity: artifact.sensitivity,
      confidence: artifact.confidence,
      complete: artifact.complete,
      retention: artifact.retention
    )
    let manifest = ContextManifest(
      taskID: taskID,
      targetLeaseID: leaseID,
      requestedScope: .conversation,
      resolvedScope: .window,
      artifacts: [expandedArtifact],
      omittedScopes: [.conversation: "semantic provider unavailable"],
      budget: ContextBudget(
        maximumArtifacts: 2,
        maximumBytes: 1_000,
        maximumTextCharacters: 1_000,
        deadline: now.addingTimeInterval(30)
      ),
      remoteTransmissionAllowed: false,
      coherent: true,
      digest: String(repeating: "a", count: 64)
    )

    XCTAssertThrowsError(try manifest.validate(now: now))
  }

  func testCapabilityGrantIsExactScopedAndUseBounded() throws {
    let now = Date()
    let grant = CapabilityGrant(
      taskID: UUID(),
      targetLeaseID: UUID(),
      exactToolName: "draft.commit",
      action: .reversibleWrite,
      scope: .conversation,
      issuedAt: now,
      expiresAt: now.addingTimeInterval(10),
      maximumUses: 1,
      nonce: "0123456789abcdef"
    )
    try grant.validate(now: now)

    XCTAssertTrue(
      grant.permits(
        toolName: "draft.commit",
        action: .reversibleWrite,
        scope: .pointedElement,
        useCount: 0,
        now: now
      ))
    XCTAssertFalse(
      grant.permits(
        toolName: "desktop.click",
        action: .reversibleWrite,
        scope: .pointedElement,
        useCount: 0,
        now: now
      ))
    XCTAssertFalse(
      grant.permits(
        toolName: "draft.commit",
        action: .reversibleWrite,
        scope: .pointedElement,
        useCount: 1,
        now: now
      ))
  }

  func testReceiptCannotReportSuccessWhenRecoveryIsUnverified() {
    let receipt = MutationReceipt(
      taskID: UUID(),
      targetLeaseID: UUID(),
      action: .reversibleWrite,
      executor: "AXDraftExecutor",
      route: "AXValue.compare-and-swap",
      beforeEvidenceArtifactIDs: [],
      postcondition: .verified(evidenceArtifactIDs: []),
      inverseOperationReference: "undo:1",
      recovery: RecoveryReceipt(
        viewport: .untouched,
        focus: .failed(reason: "focus changed"),
        pointer: .untouched,
        environment: .untouched,
        cleanupVerifiedAt: Date()
      ),
      completedAt: Date()
    )

    XCTAssertFalse(receipt.isVerifiedSuccess)
  }

  private func makeWindowLease(now: Date) -> WindowLease {
    WindowLease(
      processIdentifier: 42,
      windowID: 7,
      bundleIdentifier: "com.example.app",
      frame: ScreenRect(x: 10, y: 20, width: 800, height: 600),
      capturedAt: now,
      expiresAt: now.addingTimeInterval(30),
      userInputEpoch: 1
    )
  }

  private func makeArtifact(
    now: Date,
    taskID: UUID,
    targetLeaseID: UUID
  ) -> ContextArtifact {
    ContextArtifact(
      taskID: taskID,
      targetLeaseID: targetLeaseID,
      kind: .text,
      provider: .accessibility,
      providerVersion: "1",
      capturedAt: now,
      coherenceGroup: UUID(),
      scope: .conversation,
      mediaType: "text/plain",
      privateURI: URL(fileURLWithPath: "/tmp/context.txt"),
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
