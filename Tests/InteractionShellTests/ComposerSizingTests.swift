import AppKit
import XCTest

@testable import InteractionShell

@MainActor
final class ComposerSizingTests: XCTestCase {
  func testTopChromeUsesANativeWindowDragRegion() {
    let dragRegion = WindowDragRegionView()

    XCTAssertTrue(dragRegion.mouseDownCanMoveWindow)
    XCTAssertFalse(dragRegion.isAccessibilityElement())
  }

  func testTargetApplicationIsVisibleWithoutInventingEvidenceScope() {
    let controller = makeController(intent: "")

    XCTAssertTrue(visibleLabels(in: controller.view).contains("WeChat"))
    XCTAssertEqual(controller.view.accessibilityHelp(), "WeChat")
  }

  func testMaterialProvidesARoundedMaskForTheNativeWindowShadow() {
    let controller = makeController(intent: "")

    XCTAssertTrue(controller.hasRoundedWindowMask)
  }

  func testMarkedTextHidesThePlaceholderBeforeInputIsCommitted() {
    let controller = makeController(intent: "")

    controller.setMarkedTextForTesting("这")

    XCTAssertFalse(controller.isPlaceholderVisible)
  }

  func testMarkedTextCannotSubmitBeforeInputMethodCommitsIt() {
    let controller = makeController(intent: "")
    var submitted: String?
    controller.onSubmit = { submitted = $0 }

    controller.setMarkedTextForTesting("这")
    controller.submitCurrentTextForTesting()

    XCTAssertNil(submitted)
    XCTAssertTrue(controller.isComposerEditable)
    XCTAssertEqual(controller.submittedTurnCount, 0)
  }

  func testSubmittedTurnIsImmutableAndCompletionOpensAFreshComposer() {
    let controller = makeController(intent: "今天群里聊了什么？")

    controller.beginRunning()

    XCTAssertEqual(controller.submittedTurnCount, 1)
    XCTAssertTrue(controller.submittedTurnsAreImmutable)
    XCTAssertFalse(controller.isComposerVisible)
    XCTAssertFalse(controller.isComposerEditable)

    controller.showResult("大家主要在讨论发布节奏。", status: "已完成")
    controller.settleMotionForRendering()

    XCTAssertEqual(controller.submittedTurnCount, 1)
    XCTAssertTrue(controller.submittedTurnsAreImmutable)
    XCTAssertTrue(controller.isComposerVisible)
    XCTAssertTrue(controller.isComposerEditable)
  }

  func testCompletedProcessRemainsAnExplicitSecondaryAction() {
    let controller = makeController(intent: "总结一下")
    controller.beginRunning()
    controller.presentActivity(
      AgentActivityPresentation(
        id: "thinking",
        kind: .thinking,
        title: "Agent 正在思考",
        status: .completed
      )
    )
    controller.showResult("这是结果。", status: "已完成")

    controller.settleMotionForRendering()

    XCTAssertTrue(controller.hasCollapsedProcessSymbol)
    XCTAssertTrue(controller.completedProcessUsesText)
  }

  func testFailurePreservesTheTurnAndReturnsAFreshComposer() {
    let controller = makeController(intent: "今天群里聊了什么？")
    controller.beginRunning()
    controller.setStatus("读不到这个界面的内容 · 可重试", allowsRetry: true)
    controller.settleMotionForRendering()

    XCTAssertEqual(controller.submittedTurnCount, 1)
    XCTAssertTrue(controller.submittedTurnsAreImmutable)
    XCTAssertTrue(controller.isComposerVisible)
    XCTAssertTrue(controller.isComposerEditable)
    XCTAssertEqual(controller.visibleTerminalStatus, "读不到这个界面的内容 · 可重试")
    XCTAssertTrue(controller.isRetryVisible)
    XCTAssertGreaterThan(
      controller.preferredPanelHeight(limit: 600),
      OverlayMetrics.chromeHeight(includesAction: false) + OverlayMetrics.controlHeight
    )
  }

  func testSubmissionPreservesEveryCharacterAndFreezesTheSentTurn() {
    let controller = makeController(intent: "")
    let input = "  第一行\n第二行  "
    var submitted: String?
    controller.onSubmit = { submitted = $0 }

    controller.setComposerTextForPreview(input)
    controller.submitCurrentTextForTesting()

    XCTAssertEqual(submitted, input)
    XCTAssertEqual(controller.lastSubmittedText, input)
    XCTAssertTrue(controller.submittedTurnsAreImmutable)
    XCTAssertFalse(controller.isComposerEditable)
  }

  func testProcessShowsOnlyFourRecentRowsAndCanCollapseAgain() {
    let controller = makeController(intent: "查看过程")
    controller.beginRunning()
    for index in 0..<6 {
      controller.presentActivity(
        AgentActivityPresentation(
          id: "activity:\(index)",
          kind: .tool,
          title: "步骤 \(index)",
          status: .completed
        )
      )
    }

    XCTAssertEqual(controller.visibleActivityCount, 4)
    controller.showResult("完成。", status: "已完成")
    controller.settleMotionForRendering()
    XCTAssertEqual(controller.processAccessibilityLabel, "查看过程")

    controller.toggleLastProcessForTesting()
    XCTAssertEqual(controller.processAccessibilityLabel, "收起过程")
    controller.toggleLastProcessForTesting()
    XCTAssertEqual(controller.processAccessibilityLabel, "查看过程")
  }

  func testSubmissionHasImmediateFeedbackThenShowsOnlyRealAgentActivity() {
    let controller = makeController(intent: "查看当前内容")
    controller.beginRunning()

    controller.setStatus("Agent 正在判断需要看什么…")
    controller.setStatus("正在读取界面…")
    XCTAssertEqual(controller.visibleActivityTitles, ["正在准备请求"])

    controller.presentActivity(
      AgentActivityPresentation(
        id: "tool:call-1",
        kind: .tool,
        title: "request_context(scope: conversation, evidence: [accessibility])",
        status: .active
      )
    )
    controller.presentActivity(
      AgentActivityPresentation(
        id: "tool:call-1",
        kind: .tool,
        title: "request_context(scope: conversation, evidence: [accessibility])",
        status: .completed
      )
    )

    XCTAssertEqual(controller.visibleActivityCount, 1)
    XCTAssertEqual(
      controller.visibleActivityTitles,
      ["request_context(scope: conversation, evidence: [accessibility])"]
    )
  }

  func testRetryReusesTheImmutableSubmittedTurnWithoutCreatingAnotherTurn() {
    let input = "保持这条原始请求"
    let controller = makeController(intent: input)
    var submissions: [String] = []
    controller.onSubmit = { submissions.append($0) }
    controller.submitCurrentTextForTesting()
    controller.setStatus("读取失败", allowsRetry: true)
    controller.settleMotionForRendering()

    controller.retryLastForTesting()

    XCTAssertEqual(submissions, [input, input])
    XCTAssertEqual(controller.submittedTurnCount, 1)
    XCTAssertEqual(controller.lastSubmittedText, input)
    XCTAssertTrue(controller.submittedTurnsAreImmutable)
    XCTAssertFalse(controller.isComposerVisible)
  }

  func testAuthenticationResumeResubmitsOriginalTurnAndBindsFreshProgress() {
    let input = "  总结\n这个窗口  "
    let controller = makeController(intent: input)
    var submissions: [String] = []
    controller.onSubmit = { submissions.append($0) }
    controller.submitCurrentTextForTesting()
    controller.bind(taskID: UUID())
    controller.showActionPrompt(status: "Codex 认证失败 · 请重新连接", action: .loginCodex)
    controller.settleMotionForRendering()

    XCTAssertTrue(controller.resumeAfterAuthentication())
    XCTAssertFalse(
      controller.resumeAfterAuthentication(), "a login completion must resume only once")
    controller.bind(taskID: UUID())
    controller.presentActivity(
      AgentActivityPresentation(id: "resumed", kind: .thinking, title: "正在处理", status: .active)
    )
    XCTAssertEqual(submissions, [input, input])
    XCTAssertEqual(controller.submittedTurnCount, 1)
    XCTAssertTrue(controller.submittedTurnsAreImmutable)
    XCTAssertEqual(controller.visibleActivityCount, 1)
    controller.showResult("恢复后的结果", status: "已完成")
    controller.settleMotionForRendering()
    XCTAssertTrue(controller.isComposerEditable)
  }

  func testAuthenticationCompletionDoesNotResubmitAnUnrelatedTurn() {
    let controller = makeController(intent: "另一条请求")
    controller.beginRunning()
    XCTAssertFalse(controller.resumeAfterAuthentication())
    controller.showResult("已有答案", status: "已完成")
    XCTAssertFalse(controller.resumeAfterAuthentication())
    controller.configure(context: "新会话")
    XCTAssertFalse(controller.resumeAfterAuthentication())
  }

  func testConversationHeightIsAlwaysAWholeNumberOfLines() {
    let width = OverlayMetrics.panelWidth - OverlayMetrics.padding * 2
    let line = OverlayMetrics.resultLineHeight

    for count in [1, 3, 9, 40] {
      let controller = makeController(intent: "总结")
      controller.beginRunning()
      controller.showResult(String(repeating: "换行文本。", count: count), status: "已完成")
      let height = controller.resultHeight(fitting: width, limit: 600)
      XCTAssertEqual(
        (height / line).rounded(),
        height / line,
        accuracy: 0.0001,
        "count \(count) produced \(height), which is not a multiple of \(line)"
      )
    }
  }

  func testConversationHeightClampsToTheSuppliedLimit() {
    let controller = makeController(intent: "完整解释")
    let width = OverlayMetrics.panelWidth - OverlayMetrics.padding * 2
    let limit = OverlayMetrics.resultLineHeight * 4
    controller.beginRunning()
    controller.showResult(String(repeating: "很长的一段内容。", count: 200), status: "已完成")

    XCTAssertLessThanOrEqual(controller.resultHeight(fitting: width, limit: limit), limit)
  }

  private func makeController(intent: String) -> ComposerViewController {
    let controller = ComposerViewController()
    controller.loadView()
    controller.view.frame = NSRect(
      x: 0,
      y: 0,
      width: OverlayMetrics.panelWidth,
      height: 400
    )
    controller.configure(context: "WeChat", intent: intent)
    return controller
  }

  private func visibleLabels(in view: NSView) -> [String] {
    view.subviews.flatMap { subview -> [String] in
      let current = (subview as? NSTextField).map { [$0.stringValue] } ?? []
      return current + visibleLabels(in: subview)
    }
  }
}
