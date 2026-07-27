import Foundation
import MienContracts

public enum TaskRecoveryAuditError: Error, Equatable, Sendable {
  case duplicateEventID
  case invalidFirstEvent(taskID: UUID)
  case invalidSequence(taskID: UUID, expected: UInt64, actual: UInt64)
  case invalidPreviousState(taskID: UUID, sequence: UInt64)
}

public enum DesktopRecoveryKnowledge: Equatable, Sendable {
  case verified
  case unverified
  case unknown
}

public struct InterruptedTaskRecoveryPlan: Equatable, Sendable {
  public let taskID: UUID
  public let lastSequence: UInt64
  public let lastState: TaskState
  public let desktopRecovery: DesktopRecoveryKnowledge
  public let requiresTerminalEvent: Bool

  public init(
    taskID: UUID,
    lastSequence: UInt64,
    lastState: TaskState,
    desktopRecovery: DesktopRecoveryKnowledge,
    requiresTerminalEvent: Bool
  ) {
    self.taskID = taskID
    self.lastSequence = lastSequence
    self.lastState = lastState
    self.desktopRecovery = desktopRecovery
    self.requiresTerminalEvent = requiresTerminalEvent
  }
}

/// Audits durable task truth without reconstructing mutable runtime objects.
/// A process interruption is closed only when both local residue and desktop
/// recovery are independently known to be clean.
public enum TaskRecoveryAuditor {
  private static let terminalStates: Set<TaskState> = [
    .succeeded, .partial, .failed, .cancelled,
  ]

  public static func plans(for events: [TaskEvent]) throws -> [InterruptedTaskRecoveryPlan] {
    guard Set(events.map(\.id)).count == events.count else {
      throw TaskRecoveryAuditError.duplicateEventID
    }
    return try Dictionary(grouping: events, by: \.taskID)
      .values
      .compactMap { taskEvents in
        let ordered = taskEvents.sorted { $0.sequence < $1.sequence }
        guard let first = ordered.first,
          first.sequence == 0,
          first.previousState == nil,
          first.state == .created
        else {
          throw TaskRecoveryAuditError.invalidFirstEvent(
            taskID: taskEvents.first?.taskID ?? UUID()
          )
        }
        for (index, event) in ordered.enumerated().dropFirst() {
          let previous = ordered[index - 1]
          let expected = previous.sequence + 1
          guard event.sequence == expected else {
            throw TaskRecoveryAuditError.invalidSequence(
              taskID: event.taskID,
              expected: expected,
              actual: event.sequence
            )
          }
          guard event.previousState == previous.state else {
            throw TaskRecoveryAuditError.invalidPreviousState(
              taskID: event.taskID,
              sequence: event.sequence
            )
          }
        }
        guard let last = ordered.last, last.state != .cleanupVerified else { return nil }
        let recovery: DesktopRecoveryKnowledge =
          switch ordered.reversed().compactMap(\.desktopRecoveryVerified).first {
          case .some(true): .verified
          case .some(false): .unverified
          case .none: .unknown
          }
        return InterruptedTaskRecoveryPlan(
          taskID: last.taskID,
          lastSequence: last.sequence,
          lastState: last.state,
          desktopRecovery: recovery,
          requiresTerminalEvent: !terminalStates.contains(last.state)
        )
      }
      .sorted { $0.taskID.uuidString < $1.taskID.uuidString }
  }

  public static func recoveryEvents(
    for plan: InterruptedTaskRecoveryPlan,
    localResidueRemoved: Bool,
    now: Date = Date()
  ) -> [TaskEvent] {
    guard localResidueRemoved else { return [] }
    var events: [TaskEvent] = []
    var sequence = plan.lastSequence
    var previousState = plan.lastState
    if plan.requiresTerminalEvent {
      sequence += 1
      let failure = TaskEvent(
        taskID: plan.taskID,
        sequence: sequence,
        occurredAt: now,
        actor: .host,
        previousState: previousState,
        state: .failed,
        reason: "host process interrupted; local startup recovery completed",
        desktopRecoveryVerified: recoveryFlag(plan.desktopRecovery)
      )
      events.append(failure)
      previousState = .failed
    }
    guard plan.desktopRecovery == .verified else { return events }
    sequence += 1
    events.append(
      TaskEvent(
        taskID: plan.taskID,
        sequence: sequence,
        occurredAt: now,
        actor: .verifier,
        previousState: previousState,
        state: .cleanupVerified,
        reason: "startup recovery verified local residue and prior desktop restoration",
        desktopRecoveryVerified: true
      ))
    return events
  }

  private static func recoveryFlag(_ knowledge: DesktopRecoveryKnowledge) -> Bool? {
    switch knowledge {
    case .verified: true
    case .unverified: false
    case .unknown: nil
    }
  }
}
