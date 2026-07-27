import Foundation

public enum TaskState: String, Codable, CaseIterable, Sendable {
  case created
  case targetLocked
  case contextReady
  case degraded
  case agentRunning
  case awaitingPermission
  case executing
  case verifying
  case reversibleWindow
  case restoring
  case succeeded
  case partial
  case failed
  case cancelled
  case cleanupVerified
}

public enum TaskEventActor: String, Codable, Sendable {
  case user
  case host
  case agent
  case executor
  case verifier
}

public struct TaskEvent: Codable, Equatable, Hashable, Sendable, Identifiable {
  public let id: UUID
  public let taskID: UUID
  public let sequence: UInt64
  public let occurredAt: Date
  public let actor: TaskEventActor
  public let previousState: TaskState?
  public let state: TaskState
  public let reason: String
  public let inputDigest: String?
  public let artifactIDs: [UUID]
  public let desktopRecoveryVerified: Bool?

  public init(
    id: UUID = UUID(),
    taskID: UUID,
    sequence: UInt64,
    occurredAt: Date,
    actor: TaskEventActor,
    previousState: TaskState?,
    state: TaskState,
    reason: String,
    inputDigest: String? = nil,
    artifactIDs: [UUID] = [],
    desktopRecoveryVerified: Bool? = nil
  ) {
    self.id = id
    self.taskID = taskID
    self.sequence = sequence
    self.occurredAt = occurredAt
    self.actor = actor
    self.previousState = previousState
    self.state = state
    self.reason = reason
    self.inputDigest = inputDigest
    self.artifactIDs = artifactIDs
    self.desktopRecoveryVerified = desktopRecoveryVerified
  }
}
