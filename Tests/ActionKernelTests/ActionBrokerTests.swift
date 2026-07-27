import ActionKernel
import Foundation
import MienContracts
import PolicyKernel
import XCTest

final class ActionBrokerTests: XCTestCase {
  func testAgentCannotSubstituteAWeakerGrantForAnotherTool() async throws {
    let now = Date()
    let target = makeTarget(now: now)
    let proposal = makeProposal(target: target)
    let grant = CapabilityGrant(
      taskID: proposal.taskID,
      targetLeaseID: target.id,
      exactToolName: "desktop.click",
      action: .reversibleWrite,
      scope: .conversation,
      issuedAt: now,
      expiresAt: now.addingTimeInterval(10),
      maximumUses: 1,
      nonce: "0123456789abcdef"
    )
    let broker = ActionBroker(executors: [StubExecutor()])

    do {
      _ = try await broker.execute(
        proposal,
        grant: grant,
        policyDecision: .allow(reason: "test"),
        now: now
      )
      XCTFail("Expected exact-tool grant enforcement")
    } catch {
      XCTAssertEqual(error as? ActionBrokerError, .invalidGrant)
    }
  }

  func testExecutedButUnverifiedMutationRemainsAFailedReceipt() async throws {
    let now = Date()
    let target = makeTarget(now: now)
    let proposal = makeProposal(target: target)
    let grant = CapabilityGrant(
      taskID: proposal.taskID,
      targetLeaseID: target.id,
      exactToolName: proposal.executorName,
      action: .reversibleWrite,
      scope: .conversation,
      issuedAt: now,
      expiresAt: now.addingTimeInterval(10),
      maximumUses: 1,
      nonce: "0123456789abcdef"
    )
    let broker = ActionBroker(executors: [StubExecutor()])

    let receipt = try await broker.execute(
      proposal,
      grant: grant,
      policyDecision: .allow(reason: "test"),
      now: now
    )

    XCTAssertFalse(receipt.isVerifiedSuccess)
    guard case .failed = receipt.postcondition else {
      return XCTFail("Expected failed verification")
    }
  }

  private func makeTarget(now: Date) -> TargetLease {
    TargetLease(
      invocationSnapshotID: UUID(),
      window: WindowLease(
        processIdentifier: 42,
        windowID: 9,
        bundleIdentifier: "com.example.app",
        frame: ScreenRect(x: 0, y: 0, width: 800, height: 600),
        capturedAt: now,
        expiresAt: now.addingTimeInterval(30),
        userInputEpoch: 1
      ),
      semanticTarget: nil,
      issuedAt: now,
      expiresAt: now.addingTimeInterval(20)
    )
  }

  private func makeProposal(target: TargetLease) -> ActionProposal {
    ActionProposal(
      taskID: UUID(),
      target: target,
      executorName: "draft.commit",
      action: .reversibleWrite,
      scope: .conversation,
      parameters: ["text": "draft"],
      preconditionDigest: String(repeating: "a", count: 64),
      expectedPostcondition: "draft inserted"
    )
  }
}

private struct StubExecutor: ActionExecuting {
  let name = "draft.commit"
  let supportedActions: Set<ActionClass> = [.reversibleWrite]

  func execute(_ proposal: ActionProposal) async throws -> MutationReceipt {
    MutationReceipt(
      taskID: proposal.taskID,
      targetLeaseID: proposal.target.id,
      action: proposal.action,
      executor: name,
      route: "test",
      beforeEvidenceArtifactIDs: [],
      postcondition: .failed(reason: "not observed", evidenceArtifactIDs: []),
      inverseOperationReference: nil,
      recovery: RecoveryReceipt(
        viewport: .untouched,
        focus: .untouched,
        pointer: .untouched,
        environment: .untouched,
        cleanupVerifiedAt: Date()
      ),
      completedAt: Date()
    )
  }
}
