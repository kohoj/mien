import ActionKernel
import Foundation
import MienContracts

/// The complete v1 desktop mutation surface. It can only replace an explicit
/// selection or insert at a verified caret in one leased editable AX element.
/// It exposes no click, key press, clipboard, menu, send, shell, or generic AX primitive.
public actor AXDraftExecutor: ActionExecuting {
  private struct PreparedMutation: Sendable {
    let proposal: ActionProposal
    let handle: UUID
    let before: DraftFieldState
    let after: DraftFieldState
    let expiresAt: Date
  }

  private struct UndoMutation: Sendable {
    let taskID: UUID
    let target: TargetLease
    let handle: UUID
    let before: DraftFieldState
    let after: DraftFieldState
    let expiresAt: Date
  }

  public nonisolated let name = "draft.insert.ax"
  public nonisolated let supportedActions: Set<ActionClass> = [.reversibleWrite]

  private let driver: any DraftMutationDriving
  private let leaseDuration: TimeInterval
  private let undoDuration: TimeInterval
  private var prepared: [UUID: PreparedMutation] = [:]
  private var undo: [String: UndoMutation] = [:]

  public init(
    driver: any DraftMutationDriving = SystemAXDraftMutationDriver(),
    leaseDuration: TimeInterval = 12,
    undoDuration: TimeInterval = 30
  ) {
    self.driver = driver
    self.leaseDuration = min(max(leaseDuration, 2), 30)
    self.undoDuration = min(max(undoDuration, 5), 120)
  }

  public func prepare(
    taskID: UUID,
    window: WindowLease,
    element: AXElementFingerprint,
    scope: ContextScope,
    draft: String,
    now: Date = Date()
  ) async throws -> ActionProposal {
    purgeExpired(now: now)
    let bound = try await driver.bind(
      window: window,
      element: element,
      now: now,
      leaseDuration: leaseDuration
    )
    do {
      let after = try DraftTextTransaction.applying(draft, to: bound.state)
      let proposal = ActionProposal(
        taskID: taskID,
        target: bound.target,
        executorName: name,
        action: .reversibleWrite,
        scope: scope,
        parameters: ["text": draft, "mode": "replace-selection-or-insert-at-caret"],
        preconditionDigest: DraftTextTransaction.digest(target: bound.target, state: bound.state),
        expectedPostcondition: "the leased field equals the computed draft state"
      )
      try proposal.validate(now: now)
      prepared[proposal.id] = PreparedMutation(
        proposal: proposal,
        handle: bound.handle,
        before: bound.state,
        after: after,
        expiresAt: bound.target.expiresAt
      )
      return proposal
    } catch {
      await driver.release(handle: bound.handle)
      throw error
    }
  }

  public func execute(_ proposal: ActionProposal) async throws -> MutationReceipt {
    let now = Date()
    purgeExpired(now: now)
    guard let mutation = prepared.removeValue(forKey: proposal.id) else {
      throw DraftMutationError.proposalUnavailable
    }
    guard mutation.proposal == proposal, now < mutation.expiresAt else {
      await driver.release(handle: mutation.handle)
      throw DraftMutationError.invalidProposal
    }

    let current = try await driver.read(handle: mutation.handle, target: proposal.target, now: now)
    guard
      DraftTextTransaction.digest(target: proposal.target, state: current)
        == proposal.preconditionDigest
    else {
      await driver.release(handle: mutation.handle)
      throw DraftMutationError.stalePrecondition
    }

    try await driver.write(
      mutation.after,
      handle: mutation.handle,
      target: proposal.target,
      now: now
    )
    let observed = try await driver.read(
      handle: mutation.handle,
      target: proposal.target,
      now: Date()
    )
    guard observed == mutation.after else {
      let rolledBack = await rollback(mutation, proposal: proposal)
      if !rolledBack { throw DraftMutationError.rollbackFailed }
      return MutationReceipt(
        taskID: proposal.taskID,
        targetLeaseID: proposal.target.id,
        action: proposal.action,
        executor: name,
        route: "AXValue.compare-and-swap",
        beforeEvidenceArtifactIDs: [],
        postcondition: .failed(
          reason: "write verification failed; original text restored", evidenceArtifactIDs: []),
        inverseOperationReference: nil,
        recovery: cleanRecovery(now: Date()),
        completedAt: Date()
      )
    }

    let reference = "draft-undo:\(UUID().uuidString.lowercased())"
    undo[reference] = UndoMutation(
      taskID: proposal.taskID,
      target: proposal.target,
      handle: mutation.handle,
      before: mutation.before,
      after: mutation.after,
      expiresAt: Date().addingTimeInterval(undoDuration)
    )
    return MutationReceipt(
      taskID: proposal.taskID,
      targetLeaseID: proposal.target.id,
      action: proposal.action,
      executor: name,
      route: "AXValue.compare-and-swap",
      beforeEvidenceArtifactIDs: [],
      postcondition: .verified(evidenceArtifactIDs: []),
      inverseOperationReference: reference,
      recovery: cleanRecovery(now: Date()),
      completedAt: Date()
    )
  }

  public func undo(
    reference: String,
    taskID: UUID,
    now: Date = Date()
  ) async throws -> DraftUndoResult {
    guard let mutation = undo.removeValue(forKey: reference) else {
      throw DraftMutationError.undoUnavailable
    }
    guard mutation.taskID == taskID else {
      undo[reference] = mutation
      throw DraftMutationError.undoUnavailable
    }
    guard now < mutation.expiresAt else {
      await driver.release(handle: mutation.handle)
      throw DraftMutationError.undoExpired
    }
    let current = try await driver.read(
      handle: mutation.handle,
      target: mutation.target,
      now: now,
      permitExpiredTarget: true
    )
    guard current == mutation.after else {
      await driver.release(handle: mutation.handle)
      throw DraftMutationError.undoPreconditionChanged
    }
    try await driver.write(
      mutation.before,
      handle: mutation.handle,
      target: mutation.target,
      now: now,
      permitExpiredTarget: true
    )
    let restored = try await driver.read(
      handle: mutation.handle,
      target: mutation.target,
      now: now,
      permitExpiredTarget: true
    )
    await driver.release(handle: mutation.handle)
    guard restored == mutation.before else { throw DraftMutationError.verificationFailed }

    let receipt = MutationReceipt(
      taskID: taskID,
      targetLeaseID: mutation.target.id,
      action: .reversibleWrite,
      executor: name,
      route: "AXValue.compare-and-swap.undo",
      beforeEvidenceArtifactIDs: [],
      postcondition: .verified(evidenceArtifactIDs: []),
      inverseOperationReference: nil,
      recovery: cleanRecovery(now: now),
      completedAt: now
    )
    return DraftUndoResult(taskID: taskID, receipt: receipt)
  }

  public func discardUndo(reference: String) async {
    guard let mutation = undo.removeValue(forKey: reference) else { return }
    await driver.release(handle: mutation.handle)
  }

  private func rollback(_ mutation: PreparedMutation, proposal: ActionProposal) async -> Bool {
    do {
      try await driver.write(
        mutation.before,
        handle: mutation.handle,
        target: proposal.target,
        now: Date()
      )
      let restored = try await driver.read(
        handle: mutation.handle,
        target: proposal.target,
        now: Date()
      )
      await driver.release(handle: mutation.handle)
      return restored == mutation.before
    } catch {
      await driver.release(handle: mutation.handle)
      return false
    }
  }

  private func purgeExpired(now: Date) {
    let expiredPrepared = prepared.filter { now >= $0.value.expiresAt }
    for (id, mutation) in expiredPrepared {
      prepared.removeValue(forKey: id)
      Task { await driver.release(handle: mutation.handle) }
    }
    let expiredUndo = undo.filter { now >= $0.value.expiresAt }
    for (reference, mutation) in expiredUndo {
      undo.removeValue(forKey: reference)
      Task { await driver.release(handle: mutation.handle) }
    }
  }

  private func cleanRecovery(now: Date) -> RecoveryReceipt {
    RecoveryReceipt(
      viewport: .untouched,
      focus: .untouched,
      pointer: .untouched,
      environment: .untouched,
      cleanupVerifiedAt: now
    )
  }
}

extension DraftMutationDriving {
  fileprivate func read(
    handle: UUID,
    target: TargetLease,
    now: Date,
    permitExpiredTarget: Bool
  ) async throws -> DraftFieldState {
    if permitExpiredTarget {
      return try await read(handle: handle, target: target, now: target.issuedAt)
    }
    return try await read(handle: handle, target: target, now: now)
  }

  fileprivate func write(
    _ state: DraftFieldState,
    handle: UUID,
    target: TargetLease,
    now: Date,
    permitExpiredTarget: Bool
  ) async throws {
    try await write(
      state,
      handle: handle,
      target: target,
      now: permitExpiredTarget ? target.issuedAt : now
    )
  }
}
