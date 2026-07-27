import Foundation
import MienContracts

public enum TaskLedgerError: Error, Equatable, Sendable {
  case capsuleInvalid(String)
  case invalidTransition(from: TaskState, to: TaskState)
  case taskAlreadyClosed
  case emptyReason
}

public actor TaskLedger {
  public let capsule: TaskCapsule

  private var storage: [TaskEvent]

  public init(capsule: TaskCapsule, now: Date = Date()) throws {
    do {
      try capsule.validate(now: now)
    } catch {
      throw TaskLedgerError.capsuleInvalid(error.localizedDescription)
    }
    self.capsule = capsule
    self.storage = [
      TaskEvent(
        taskID: capsule.id,
        sequence: 0,
        occurredAt: now,
        actor: .host,
        previousState: nil,
        state: .created,
        reason: "task capsule accepted"
      )
    ]
  }

  public var currentState: TaskState {
    storage.last?.state ?? .created
  }

  public var terminalOutcome: TaskState? {
    storage.reversed().first { event in
      [.succeeded, .partial, .failed, .cancelled].contains(event.state)
    }?.state
  }

  public func events(after sequence: UInt64? = nil) -> [TaskEvent] {
    guard let sequence else { return storage }
    return storage.filter { $0.sequence > sequence }
  }

  @discardableResult
  public func transition(
    to next: TaskState,
    actor: TaskEventActor,
    reason: String,
    inputDigest: String? = nil,
    artifactIDs: [UUID] = [],
    desktopRecoveryVerified: Bool? = nil,
    now: Date = Date()
  ) throws -> TaskEvent {
    let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reason.isEmpty else { throw TaskLedgerError.emptyReason }

    let current = currentState
    guard current != .cleanupVerified else {
      throw TaskLedgerError.taskAlreadyClosed
    }
    guard Self.allowedTransitions[current, default: []].contains(next) else {
      throw TaskLedgerError.invalidTransition(from: current, to: next)
    }

    let event = TaskEvent(
      taskID: capsule.id,
      sequence: UInt64(storage.count),
      occurredAt: now,
      actor: actor,
      previousState: current,
      state: next,
      reason: reason,
      inputDigest: inputDigest,
      artifactIDs: artifactIDs,
      desktopRecoveryVerified: desktopRecoveryVerified
    )
    storage.append(event)
    return event
  }

  private static let allowedTransitions: [TaskState: Set<TaskState>] = [
    .created: [.targetLocked, .failed, .cancelled],
    .targetLocked: [.contextReady, .degraded, .failed, .cancelled],
    .contextReady: [.agentRunning, .failed, .cancelled],
    .degraded: [.agentRunning, .failed, .cancelled],
    .agentRunning: [.awaitingPermission, .executing, .verifying, .succeeded, .failed, .cancelled],
    .awaitingPermission: [.agentRunning, .executing, .failed, .cancelled],
    .executing: [.verifying, .restoring, .failed, .cancelled],
    .verifying: [.reversibleWindow, .restoring, .succeeded, .partial, .failed, .cancelled],
    .reversibleWindow: [.restoring, .succeeded, .partial, .failed, .cancelled],
    .restoring: [.succeeded, .partial, .failed, .cancelled],
    .succeeded: [.cleanupVerified],
    .partial: [.cleanupVerified],
    .failed: [.restoring, .cleanupVerified],
    .cancelled: [.restoring, .cleanupVerified],
    .cleanupVerified: [],
  ]
}
