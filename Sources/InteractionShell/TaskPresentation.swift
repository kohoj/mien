import Foundation
import MienContracts

public enum TaskPresentationAction: Equatable, Sendable {
  case insertDraft
  case undoDraft
  case loginCodex
}

public struct TaskPresentation: Equatable, Sendable {
  public let taskID: UUID
  public let sequence: UInt64
  public let status: String
  public let result: String?
  public let allowsRetry: Bool
  public let action: TaskPresentationAction?

  public init(
    taskID: UUID,
    sequence: UInt64,
    status: String,
    result: String?,
    allowsRetry: Bool,
    action: TaskPresentationAction? = nil
  ) {
    self.taskID = taskID
    self.sequence = sequence
    self.status = status
    self.result = result
    self.allowsRetry = allowsRetry
    self.action = action
  }
}

public struct TaskPresentationReducer: Sendable {
  public init() {}

  public func reduce(
    events: [TaskEvent],
    result: String? = nil,
    action: TaskPresentationAction? = nil
  ) -> TaskPresentation? {
    guard let latest = events.last else { return nil }
    let terminal = events.reversed().first {
      [.succeeded, .partial, .failed, .cancelled].contains($0.state)
    }?.state
    let cleanupVerified = latest.state == .cleanupVerified
    let effectiveState = terminal ?? latest.state

    let status: String
    let allowsRetry: Bool
    switch effectiveState {
    case .created, .targetLocked:
      status = "正在读取上下文…"
      allowsRetry = false
    case .contextReady:
      status = "上下文已就绪"
      allowsRetry = false
    case .degraded:
      status = "仅能读取部分上下文"
      allowsRetry = false
    case .agentRunning:
      status = "Codex 正在处理…"
      allowsRetry = false
    case .awaitingPermission:
      status = result == nil ? "等待确认…" : "草稿已生成"
      allowsRetry = false
    case .executing, .verifying:
      status = "正在验证…"
      allowsRetry = false
    case .reversibleWindow:
      status = "已插入 · 可撤销"
      allowsRetry = false
    case .restoring:
      status = "正在恢复现场…"
      allowsRetry = false
    case .succeeded:
      status = cleanupVerified ? "已完成" : "结果已生成 · 清理待恢复"
      allowsRetry = false
    case .partial:
      status = "部分完成"
      allowsRetry = true
    case .failed:
      status = "任务未完成"
      allowsRetry = true
    case .cancelled:
      status = "已取消"
      allowsRetry = true
    case .cleanupVerified:
      return nil
    }
    let visibleResult: String? =
      switch effectiveState {
      case .awaitingPermission, .reversibleWindow, .succeeded: result
      default: nil
      }
    let visibleAction: TaskPresentationAction? =
      switch (effectiveState, action) {
      case (.awaitingPermission, .insertDraft): .insertDraft
      case (.reversibleWindow, .undoDraft): .undoDraft
      default: nil
      }
    return TaskPresentation(
      taskID: latest.taskID,
      sequence: latest.sequence,
      status: status,
      result: visibleResult,
      allowsRetry: allowsRetry,
      action: visibleAction
    )
  }
}
