import Foundation
import MienContracts
import PolicyKernel

public struct ActionProposal: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let taskID: UUID
  public let target: TargetLease
  public let executorName: String
  public let action: ActionClass
  public let scope: ContextScope
  public let parameters: [String: String]
  public let preconditionDigest: String
  public let expectedPostcondition: String

  public init(
    id: UUID = UUID(),
    taskID: UUID,
    target: TargetLease,
    executorName: String,
    action: ActionClass,
    scope: ContextScope,
    parameters: [String: String],
    preconditionDigest: String,
    expectedPostcondition: String
  ) {
    self.id = id
    self.taskID = taskID
    self.target = target
    self.executorName = executorName
    self.action = action
    self.scope = scope
    self.parameters = parameters
    self.preconditionDigest = preconditionDigest
    self.expectedPostcondition = expectedPostcondition
  }

  public func validate(now: Date) throws {
    try target.validate(now: now)
    guard !executorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ContractValidationError.empty("action.executorName")
    }
    guard preconditionDigest.count == 64,
      preconditionDigest.allSatisfy(\.isHexDigit)
    else {
      throw ContractValidationError.invalid("action.preconditionDigest")
    }
    guard !expectedPostcondition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ContractValidationError.empty("action.expectedPostcondition")
    }
  }
}

public protocol ActionExecuting: Sendable {
  var name: String { get }
  var supportedActions: Set<ActionClass> { get }
  func execute(_ proposal: ActionProposal) async throws -> MutationReceipt
}

public enum ActionBrokerError: Error, Equatable, Sendable {
  case policyDenied(String)
  case approvalRequired(String)
  case invalidGrant
  case targetBusy
  case executorUnavailable
  case executorDoesNotSupportAction
  case malformedReceipt
  case invalidProposal
}

public actor ActionBroker {
  private struct TargetKey: Hashable {
    let processIdentifier: Int32
    let windowID: UInt32
  }

  private let executors: [String: any ActionExecuting]
  private var activeTargets: Set<TargetKey> = []
  private var grantUseCounts: [UUID: Int] = [:]

  public init(executors: [any ActionExecuting]) {
    self.executors = Dictionary(uniqueKeysWithValues: executors.map { ($0.name, $0) })
  }

  public func execute(
    _ proposal: ActionProposal,
    grant: CapabilityGrant,
    policyDecision: PolicyDecision,
    now: Date = Date()
  ) async throws -> MutationReceipt {
    switch policyDecision {
    case .deny(let reason): throw ActionBrokerError.policyDenied(reason)
    case .requireApproval(let reason): throw ActionBrokerError.approvalRequired(reason)
    case .allow: break
    }

    do {
      try proposal.validate(now: now)
    } catch {
      throw ActionBrokerError.invalidProposal
    }
    let useCount = grantUseCounts[grant.id, default: 0]
    guard grant.taskID == proposal.taskID,
      grant.targetLeaseID == proposal.target.id,
      grant.permits(
        toolName: proposal.executorName,
        action: proposal.action,
        scope: proposal.scope,
        useCount: useCount,
        now: now
      )
    else {
      throw ActionBrokerError.invalidGrant
    }
    let targetKey = TargetKey(
      processIdentifier: proposal.target.window.processIdentifier,
      windowID: proposal.target.window.windowID
    )
    guard !activeTargets.contains(targetKey) else {
      throw ActionBrokerError.targetBusy
    }
    guard let executor = executors[proposal.executorName] else {
      throw ActionBrokerError.executorUnavailable
    }
    guard executor.supportedActions.contains(proposal.action) else {
      throw ActionBrokerError.executorDoesNotSupportAction
    }

    activeTargets.insert(targetKey)
    grantUseCounts[grant.id] = useCount + 1
    defer { activeTargets.remove(targetKey) }

    let receipt = try await executor.execute(proposal)
    guard receipt.taskID == proposal.taskID,
      receipt.targetLeaseID == proposal.target.id,
      receipt.action == proposal.action,
      receipt.executor == proposal.executorName
    else {
      throw ActionBrokerError.malformedReceipt
    }
    return receipt
  }
}
