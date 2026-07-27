import Foundation

public enum PostconditionVerdict: Codable, Equatable, Hashable, Sendable {
  case verified(evidenceArtifactIDs: [UUID])
  case failed(reason: String, evidenceArtifactIDs: [UUID])
}

public enum RecoveryFacet: Codable, Equatable, Hashable, Sendable {
  case untouched
  case restored
  case failed(reason: String)
  case suppressedByUserInput

  public var isClean: Bool {
    switch self {
    case .untouched, .restored: true
    case .failed, .suppressedByUserInput: false
    }
  }
}

public struct RecoveryReceipt: Codable, Equatable, Hashable, Sendable {
  public let viewport: RecoveryFacet
  public let focus: RecoveryFacet
  public let pointer: RecoveryFacet
  public let environment: RecoveryFacet
  public let cleanupVerifiedAt: Date

  public init(
    viewport: RecoveryFacet,
    focus: RecoveryFacet,
    pointer: RecoveryFacet,
    environment: RecoveryFacet,
    cleanupVerifiedAt: Date
  ) {
    self.viewport = viewport
    self.focus = focus
    self.pointer = pointer
    self.environment = environment
    self.cleanupVerifiedAt = cleanupVerifiedAt
  }

  public var isClean: Bool {
    viewport.isClean && focus.isClean && pointer.isClean && environment.isClean
  }
}

public struct MutationReceipt: Codable, Equatable, Hashable, Sendable, Identifiable {
  public let id: UUID
  public let taskID: UUID
  public let targetLeaseID: UUID
  public let action: ActionClass
  public let executor: String
  public let route: String
  public let beforeEvidenceArtifactIDs: [UUID]
  public let postcondition: PostconditionVerdict
  public let inverseOperationReference: String?
  public let recovery: RecoveryReceipt
  public let completedAt: Date

  public init(
    id: UUID = UUID(),
    taskID: UUID,
    targetLeaseID: UUID,
    action: ActionClass,
    executor: String,
    route: String,
    beforeEvidenceArtifactIDs: [UUID],
    postcondition: PostconditionVerdict,
    inverseOperationReference: String?,
    recovery: RecoveryReceipt,
    completedAt: Date
  ) {
    self.id = id
    self.taskID = taskID
    self.targetLeaseID = targetLeaseID
    self.action = action
    self.executor = executor
    self.route = route
    self.beforeEvidenceArtifactIDs = beforeEvidenceArtifactIDs
    self.postcondition = postcondition
    self.inverseOperationReference = inverseOperationReference
    self.recovery = recovery
    self.completedAt = completedAt
  }

  public var isVerifiedSuccess: Bool {
    guard case .verified = postcondition else { return false }
    return recovery.isClean
  }
}
