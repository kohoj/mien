import AppKit
import WebKit
import XCTest

@testable import InteractionShell

@MainActor
final class InteractionResponsivenessTests: XCTestCase {
  func testTerminalResultReleasesComposerWithoutAnAnimationDeadline() {
    let controller = ComposerViewController()
    controller.loadViewIfNeeded()
    controller.configure(context: "测试窗口", intent: "总结")
    controller.beginRunning()
    controller.presentActivity(
      AgentActivityPresentation(id: "thinking", kind: .thinking, title: "思考", status: .active)
    )
    controller.showResult("结果", status: "已完成")
    XCTAssertTrue(controller.isComposerVisible)
    XCTAssertTrue(controller.isComposerEditable)
  }

  func testSubmissionAndAuthenticationFailureDoNotAllocateAWebView() {
    let controller = ComposerViewController()
    controller.loadViewIfNeeded()
    controller.configure(context: "测试窗口", intent: "总结")
    controller.beginRunning()
    XCTAssertEqual(webViewCount(in: controller.view), 0)
    controller.showActionPrompt(status: "请连接 Codex", action: .loginCodex)
    XCTAssertEqual(webViewCount(in: controller.view), 0)
  }

  func testOnlyAResultCreatesRendererAndResetReleasesIt() {
    let controller = ComposerViewController()
    controller.loadViewIfNeeded()
    controller.configure(context: "测试窗口", intent: "总结")
    controller.beginRunning()
    controller.showResult("结果", status: "已完成")
    XCTAssertEqual(webViewCount(in: controller.view), 1)
    controller.configure(context: "新窗口")
    XCTAssertEqual(webViewCount(in: controller.view), 0)
  }

  func testAnotherRetryableFailureReenablesTheSameRetryControl() throws {
    let controller = ComposerViewController()
    controller.loadViewIfNeeded()
    controller.configure(context: "测试窗口", intent: "总结")
    controller.beginRunning()
    controller.setStatus("连接失败", allowsRetry: true)
    controller.retryLastForTesting()
    controller.setStatus("连接仍不可用", allowsRetry: true)
    let button = try XCTUnwrap(
      descendants(of: controller.view).compactMap { $0 as? NSButton }
        .first { $0.title == "重试" })
    XCTAssertTrue(button.isEnabled)
    XCTAssertFalse(button.isHidden)
  }

  private func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
  }

  private func webViewCount(in view: NSView) -> Int {
    (view is WKWebView ? 1 : 0) + view.subviews.reduce(0) { $0 + webViewCount(in: $1) }
  }
}
