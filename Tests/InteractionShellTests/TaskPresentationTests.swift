import Foundation
import InteractionShell
import MienContracts
import XCTest

final class TaskPresentationTests: XCTestCase {
  func testActivityLanguageComesFromTypedMetadataAndDoesNotClaimTaskSuccess() {
    let context = AgentActivityPresentation(
      id: "context", kind: .tool, toolName: "request_context", status: .completed)
    let outcome = AgentActivityPresentation(
      id: "outcome", kind: .tool, toolName: "submit_outcome", status: .completed)
    let unknown = AgentActivityPresentation(
      id: "unknown", kind: .tool, toolName: "private/tool/input", status: .active)
    XCTAssertEqual(context.title, "已确认所需内容")
    XCTAssertEqual(outcome.title, "回答已提交")
    XCTAssertEqual(unknown.title, "正在处理")
    XCTAssertFalse(outcome.title.contains("任务成功"))
  }

  func testCleanupProjectsThePreservedTerminalOutcome() throws {
    let taskID = UUID()
    let events = [
      event(taskID: taskID, sequence: 0, previous: nil, state: .created),
      event(taskID: taskID, sequence: 1, previous: .created, state: .targetLocked),
      event(taskID: taskID, sequence: 2, previous: .targetLocked, state: .contextReady),
      event(taskID: taskID, sequence: 3, previous: .contextReady, state: .agentRunning),
      event(taskID: taskID, sequence: 4, previous: .agentRunning, state: .succeeded),
      event(taskID: taskID, sequence: 5, previous: .succeeded, state: .cleanupVerified),
    ]

    let presentation = try XCTUnwrap(
      TaskPresentationReducer().reduce(events: events, result: "Draft")
    )

    XCTAssertEqual(presentation.status, "已完成")
    XCTAssertEqual(presentation.result, "Draft")
    XCTAssertEqual(presentation.sequence, 5)
    XCTAssertEqual(presentation.outcome, .success)
  }

  func testFailedTaskNeverProjectsAgentTextAsAResult() throws {
    let taskID = UUID()
    let events = [
      event(taskID: taskID, sequence: 0, previous: nil, state: .created),
      event(taskID: taskID, sequence: 1, previous: .created, state: .failed),
    ]

    let presentation = try XCTUnwrap(
      TaskPresentationReducer().reduce(events: events, result: "partial model text")
    )

    XCTAssertEqual(presentation.status, "任务未完成")
    XCTAssertNil(presentation.result)
    XCTAssertTrue(presentation.allowsRetry)
    XCTAssertEqual(presentation.outcome, .failure)
  }

  func testAuthenticationFailureOffersLoginAfterCleanupWithoutRetrying() throws {
    let taskID = UUID()
    let events = [
      event(taskID: taskID, sequence: 0, previous: nil, state: .created),
      event(
        taskID: taskID, sequence: 1, previous: .created, state: .failed,
        reason: "agent authentication required"
      ),
      event(taskID: taskID, sequence: 2, previous: .failed, state: .cleanupVerified),
    ]
    let presentation = try XCTUnwrap(
      TaskPresentationReducer().reduce(events: events, result: "unvalidated text")
    )

    XCTAssertEqual(presentation.status, "账户连接已失效 · 请重新连接")
    XCTAssertEqual(presentation.action, .loginCodex)
    XCTAssertEqual(presentation.outcome, .actionRequired)
    XCTAssertFalse(presentation.allowsRetry)
    XCTAssertNil(presentation.result)
  }

  func testApprovalAndReversibleStatesProjectActionRequiredTone() throws {
    let taskID = UUID()
    let awaiting = [
      event(taskID: taskID, sequence: 0, previous: nil, state: .created),
      event(taskID: taskID, sequence: 1, previous: .created, state: .awaitingPermission),
    ]
    let presentation = try XCTUnwrap(
      TaskPresentationReducer().reduce(
        events: awaiting,
        result: "草稿",
        action: .insertDraft
      )
    )

    XCTAssertEqual(presentation.outcome, .actionRequired)
    XCTAssertEqual(presentation.action, .insertDraft)
  }

  /// A bare "任务未完成" tells the user nothing about what to do next, and the
  /// ledger already records the cause, so the recognised causes must reach the
  /// status line.
  func testFailureStatusNamesTheLedgerReasonTheUserCanActOn() throws {
    let expected = [
      "no usable context artifact": "读不到这个界面的内容 · 可重试",
      "context preflight policy denied the target": "此内容受保护",
      "policy kept context inside the local trust boundary": "上下文仅在本机",
      "pinned ACP runtime unavailable": "连接尚未就绪 · 可重试",
      "screen recording permission unavailable for the pixel fallback":
        "需要屏幕录制权限 · 去系统设置开启",
      "task deadline elapsed before the agent turn completed": "等待回答超时 · 可重试",
      "agent runtime failed": "生成回答时出错 · 可重试",
      "agent protocol violation: missingContextDecision":
        "未能确定需要读取的内容 · 可重试",
      "agent protocol violation: missingOutcome": "未收到完整回答 · 可重试",
      "agent protocol violation: malformedOutcome": "回答格式不正确 · 可重试",
      // Timeout reasons carry the ACP method name and are matched by prefix.
      "ACP request deadline exceeded: session/prompt": "等待回答超时 · 可重试",
      // Context failures now carry the per-provider causes in parentheses.
      "no usable context artifact (longview: target changed)":
        "读不到这个界面的内容 · 可重试",
      "no usable context artifact (longview: processFailed(status: 74, code: capture_failed, message: Long screenshot failed: overlapUnavailable.))":
        "无法读取更早的内容 · 可重试",
      "no usable context artifact (accessibility: provider returned no valid artifacts)":
        "界面内容读取失败 · 可重试",
      "no usable context artifact (accessibility: provider returned no valid artifacts (artifact scope semanticRegion exceeded requested scope pointedElement))":
        "界面内容读取失败 · 可重试",
    ]
    for (reason, status) in expected {
      let taskID = UUID()
      let events = [
        event(taskID: taskID, sequence: 0, previous: nil, state: .created),
        event(taskID: taskID, sequence: 1, previous: .created, state: .failed, reason: reason),
      ]
      let presentation = try XCTUnwrap(TaskPresentationReducer().reduce(events: events))
      XCTAssertEqual(presentation.status, status, "reason: \(reason)")
      XCTAssertTrue(presentation.allowsRetry)
    }
  }

  /// An unrecognised reason must not leak internal prose into the UI.
  func testUnknownFailureReasonFallsBackToTheGenericWording() throws {
    let taskID = UUID()
    let events = [
      event(taskID: taskID, sequence: 0, previous: nil, state: .created),
      event(
        taskID: taskID, sequence: 1, previous: .created, state: .failed,
        reason: "some internal invariant tripped"
      ),
    ]
    let presentation = try XCTUnwrap(TaskPresentationReducer().reduce(events: events))
    XCTAssertEqual(presentation.status, "任务未完成")
  }

  private func event(
    taskID: UUID,
    sequence: UInt64,
    previous: TaskState?,
    state: TaskState,
    reason: String = "test"
  ) -> TaskEvent {
    TaskEvent(
      taskID: taskID,
      sequence: sequence,
      occurredAt: Date(),
      actor: .host,
      previousState: previous,
      state: state,
      reason: reason
    )
  }
}
