import Foundation

public enum ActionClass: String, Codable, CaseIterable, Hashable, Sendable {
  case read
  case proposeDraft
  case reversibleWrite
  case externalCommit
  case destructive
  case remember
}

public enum ApprovalPolicy: String, Codable, Sendable {
  case readOnly
  case previewReversibleWrites
  case confirmExternalCommit
  case confirmEveryMutation
}

public struct TaskCapsule: Codable, Equatable, Hashable, Sendable, Identifiable, ContractValidating
{
  public let id: UUID
  public let createdAt: Date
  public let intent: String
  public let targetLeaseID: UUID
  public let contextManifestID: UUID
  public let desiredOutcome: String
  public let allowedActions: Set<ActionClass>
  public let approvalPolicy: ApprovalPolicy
  public let deadline: Date
  public let acpSessionID: String?

  public init(
    id: UUID = UUID(),
    createdAt: Date,
    intent: String,
    targetLeaseID: UUID,
    contextManifestID: UUID,
    desiredOutcome: String,
    allowedActions: Set<ActionClass>,
    approvalPolicy: ApprovalPolicy,
    deadline: Date,
    acpSessionID: String? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.intent = intent
    self.targetLeaseID = targetLeaseID
    self.contextManifestID = contextManifestID
    self.desiredOutcome = desiredOutcome
    self.allowedActions = allowedActions
    self.approvalPolicy = approvalPolicy
    self.deadline = deadline
    self.acpSessionID = acpSessionID
  }

  public func validate(now: Date) throws {
    guard !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ContractValidationError.empty("task.intent")
    }
    guard !desiredOutcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ContractValidationError.empty("task.desiredOutcome")
    }
    guard !allowedActions.isEmpty else {
      throw ContractValidationError.empty("task.allowedActions")
    }
    guard deadline > createdAt, now < deadline else {
      throw ContractValidationError.expired("task.deadline")
    }
    if allowedActions.contains(.destructive), approvalPolicy != .confirmEveryMutation {
      throw ContractValidationError.unauthorized("destructive tasks require confirmation")
    }
    if allowedActions.contains(.externalCommit),
      approvalPolicy != .confirmExternalCommit,
      approvalPolicy != .confirmEveryMutation
    {
      throw ContractValidationError.unauthorized("external commits require confirmation")
    }
  }
}

public struct CapabilityGrant: Codable, Equatable, Hashable, Sendable, Identifiable,
  ContractValidating
{
  public let id: UUID
  public let taskID: UUID
  public let targetLeaseID: UUID
  public let exactToolName: String
  public let action: ActionClass
  public let scope: ContextScope
  public let issuedAt: Date
  public let expiresAt: Date
  public let maximumUses: Int
  public let nonce: String
  public let approvalReference: String?

  public init(
    id: UUID = UUID(),
    taskID: UUID,
    targetLeaseID: UUID,
    exactToolName: String,
    action: ActionClass,
    scope: ContextScope,
    issuedAt: Date,
    expiresAt: Date,
    maximumUses: Int,
    nonce: String,
    approvalReference: String? = nil
  ) {
    self.id = id
    self.taskID = taskID
    self.targetLeaseID = targetLeaseID
    self.exactToolName = exactToolName
    self.action = action
    self.scope = scope
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.maximumUses = maximumUses
    self.nonce = nonce
    self.approvalReference = approvalReference
  }

  public func validate(now: Date) throws {
    guard !exactToolName.isEmpty else {
      throw ContractValidationError.empty("grant.exactToolName")
    }
    guard maximumUses > 0 else {
      throw ContractValidationError.invalid("grant.maximumUses")
    }
    guard nonce.count >= 16 else {
      throw ContractValidationError.invalid("grant.nonce")
    }
    guard expiresAt > issuedAt, now < expiresAt else {
      throw ContractValidationError.expired("grant")
    }
    if action == .externalCommit || action == .destructive {
      guard approvalReference?.isEmpty == false else {
        throw ContractValidationError.unauthorized("high-risk grant lacks approval reference")
      }
    }
  }

  public func permits(
    toolName: String,
    action requestedAction: ActionClass,
    scope requestedScope: ContextScope,
    useCount: Int,
    now: Date
  ) -> Bool {
    (try? validate(now: now)) != nil
      && toolName == exactToolName
      && requestedAction == action
      && scope.encompasses(requestedScope)
      && useCount < maximumUses
  }
}
