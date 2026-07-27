import ActionKernel
import Foundation
import MienContracts

public struct DraftSelection: Codable, Equatable, Hashable, Sendable {
  public let location: Int
  public let length: Int

  public init(location: Int, length: Int) {
    self.location = location
    self.length = length
  }

  public func validate(utf16Count: Int) throws {
    guard location >= 0, length >= 0, location <= utf16Count,
      length <= utf16Count - location
    else {
      throw DraftMutationError.invalidSelection
    }
  }
}

public struct DraftFieldState: Equatable, Sendable {
  public let value: String
  public let selection: DraftSelection?

  public init(value: String, selection: DraftSelection?) {
    self.value = value
    self.selection = selection
  }
}

public struct BoundDraftField: Equatable, Sendable {
  public let handle: UUID
  public let target: TargetLease
  public let state: DraftFieldState

  public init(handle: UUID, target: TargetLease, state: DraftFieldState) {
    self.handle = handle
    self.target = target
    self.state = state
  }
}

public protocol DraftMutationDriving: Sendable {
  func bind(
    window: WindowLease,
    element: AXElementFingerprint,
    now: Date,
    leaseDuration: TimeInterval
  ) async throws -> BoundDraftField

  func read(handle: UUID, target: TargetLease, now: Date) async throws -> DraftFieldState

  func write(
    _ state: DraftFieldState,
    handle: UUID,
    target: TargetLease,
    now: Date
  ) async throws

  func release(handle: UUID) async
}

public struct DraftUndoResult: Equatable, Sendable {
  public let taskID: UUID
  public let receipt: MutationReceipt

  public init(taskID: UUID, receipt: MutationReceipt) {
    self.taskID = taskID
    self.receipt = receipt
  }
}

public enum DraftMutationError: Error, Equatable, Sendable {
  case emptyDraft
  case draftTooLarge
  case accessibilityPermissionMissing
  case applicationUnavailable
  case targetChanged
  case targetExpired
  case fieldNotEditable
  case protectedField
  case selectionUnavailable
  case invalidSelection
  case stalePrecondition
  case writeFailed(Int32)
  case verificationFailed
  case rollbackFailed
  case proposalUnavailable
  case invalidProposal
  case undoUnavailable
  case undoExpired
  case undoPreconditionChanged
}
