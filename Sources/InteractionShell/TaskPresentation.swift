import Foundation
import MienContracts

public enum TaskPresentationAction: Equatable, Sendable {
  case insertDraft
  case undoDraft
  case loginCodex
}

public enum TaskPresentationOutcome: Equatable, Sendable {
  case success
  case actionRequired
  case warning
  case failure
}

public struct AgentActivityPresentation: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case host
    case thinking
    case tool
    case plan
  }

  public enum Status: Equatable, Sendable {
    case active
    case completed
    case failed
  }

  public let id: String
  public let kind: Kind
  public let title: String
  public let status: Status

  public init(id: String, kind: Kind, title: String, status: Status) {
    self.id = id
    self.kind = kind
    self.title = title
    self.status = status
  }

  /// Presentation owns user-facing language. Only standardized kind, status,
  /// and executable tool identity enter this projection, never Agent prose.
  public init(id: String, kind: Kind, toolName: String?, status: Status) {
    let labels: (String, String, String)
    switch (kind, toolName) {
    case (.tool, "request_context"):
      labels = ("准备所需内容", "已确认所需内容", "无法取得所需内容")
    case (.tool, "submit_outcome"):
      labels = ("整理回答", "回答已提交", "回答未能提交")
    case (.thinking, _):
      labels = ("正在思考", "思考结束", "思考中断")
    case (.plan, _):
      labels = ("规划处理步骤", "处理步骤已就绪", "规划中断")
    case (.host, _):
      labels = ("正在准备请求", "请求已准备", "请求未能准备")
    case (.tool, _):
      labels = ("正在处理", "处理步骤已结束", "处理步骤失败")
    }
    let title: String
    switch status {
    case .active: title = labels.0
    case .completed: title = labels.1
    case .failed: title = labels.2
    }
    self.init(id: id, kind: kind, title: title, status: status)
  }
}

public struct TaskPresentation: Equatable, Sendable {
  public let taskID: UUID
  public let sequence: UInt64
  public let status: String
  public let result: String?
  public let allowsRetry: Bool
  public let action: TaskPresentationAction?
  public let outcome: TaskPresentationOutcome

  public init(
    taskID: UUID,
    sequence: UInt64,
    status: String,
    result: String?,
    allowsRetry: Bool,
    action: TaskPresentationAction? = nil,
    outcome: TaskPresentationOutcome = .success
  ) {
    self.taskID = taskID
    self.sequence = sequence
    self.status = status
    self.result = result
    self.allowsRetry = allowsRetry
    self.action = action
    self.outcome = outcome
  }
}

public struct TaskPresentationReducer: Sendable {
  public init() {}

  /// Maps a ledger failure reason to a phrase the user can act on. The ledger
  /// reasons are engineering prose; these state the same facts in terms of what
  /// the user can do next. Unrecognised reasons keep the generic wording rather
  /// than exposing internal text.
  static func failureStatus(reason: String) -> String {
    // Timeout reasons carry the ACP method name, and context failures carry the
    // per-provider causes in parentheses, so both are matched by prefix.
    if reason.hasPrefix("ACP request deadline exceeded") {
      return "等待回答超时 · 可重试"
    }
    if reason == "agent protocol violation: missingContextDecision" {
      return "未能确定需要读取的内容 · 可重试"
    }
    if reason == "agent protocol violation: missingOutcome" {
      return "未收到完整回答 · 可重试"
    }
    if reason.hasPrefix("agent protocol violation:") {
      return "回答格式不正确 · 可重试"
    }
    if reason.contains("Long screenshot failed: overlapUnavailable") {
      return "无法读取更早的内容 · 可重试"
    }
    if reason.contains("accessibility: provider returned no valid artifacts") {
      return "界面内容读取失败 · 可重试"
    }
    if reason.hasPrefix("no usable context artifact") {
      return "读不到这个界面的内容 · 可重试"
    }
    switch reason {
    case "context preflight policy denied the target":
      return "此内容受保护"
    case "policy kept context inside the local trust boundary":
      return "上下文仅在本机"
    case "pinned ACP runtime unavailable":
      return "连接尚未就绪 · 可重试"
    case "screen recording permission unavailable for the pixel fallback":
      return "需要屏幕录制权限 · 去系统设置开启"
    case "accessibility permission unavailable for Agent-requested evidence":
      return "需要允许读取界面"
    case "screen recording permission unavailable for Agent-requested evidence":
      return "需要允许理解画面"
    case "agent returned an invalid structured protocol envelope",
      "agent requested evidence outside the advertised capability catalog",
      "agent turn ended before a typed result":
      return "未收到完整回答 · 可重试"
    case "agent task session unavailable":
      return "连接已中断 · 可重试"
    case "task deadline elapsed before the agent turn completed":
      return "等待回答超时 · 可重试"
    case "agent runtime failed":
      return "生成回答时出错 · 可重试"
    case "agent authentication required":
      return "账户连接已失效 · 请重新连接"
    case "agent model catalog unavailable":
      return "模型列表读取失败 · 可重试"
    default:
      return "任务未完成"
    }
  }

  public func reduce(
    events: [TaskEvent],
    result: String? = nil,
    action: TaskPresentationAction? = nil
  ) -> TaskPresentation? {
    guard let latest = events.last else { return nil }
    let terminalEvent = events.reversed().first {
      [.succeeded, .partial, .failed, .cancelled].contains($0.state)
    }
    let terminal = terminalEvent?.state
    let cleanupVerified = latest.state == .cleanupVerified
    let effectiveState = terminal ?? latest.state
    let authenticationRequired =
      effectiveState == .failed && terminalEvent?.reason == "agent authentication required"

    let status: String
    let allowsRetry: Bool
    switch effectiveState {
    case .created, .targetLocked:
      status = "正在锁定目标…"
      allowsRetry = false
    case .contextPlanning:
      status = "正在确认所需内容…"
      allowsRetry = false
    case .contextReady:
      status = "上下文已就绪"
      allowsRetry = false
    case .degraded:
      status = "仅能读取部分上下文"
      allowsRetry = false
    case .agentRunning:
      status = "正在整理回答…"
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
      // "任务未完成" alone gives the user nothing to act on, while the ledger
      // already records why. Surface a readable form of that reason.
      status = Self.failureStatus(reason: (terminalEvent ?? latest).reason)
      allowsRetry = !authenticationRequired
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
      case (.failed, _) where authenticationRequired: .loginCodex
      case (.awaitingPermission, .insertDraft): .insertDraft
      case (.reversibleWindow, .undoDraft): .undoDraft
      default: nil
      }
    let outcome: TaskPresentationOutcome =
      switch effectiveState {
      case .failed where authenticationRequired:
        .actionRequired
      case .awaitingPermission, .reversibleWindow:
        .actionRequired
      case .partial, .failed, .cancelled:
        .failure
      default:
        .success
      }
    return TaskPresentation(
      taskID: latest.taskID,
      sequence: latest.sequence,
      status: status,
      result: visibleResult,
      allowsRetry: allowsRetry,
      action: visibleAction,
      outcome: outcome
    )
  }
}
