import AppKit
import WebKit
import XCTest

@testable import InteractionShell

@MainActor
final class ConversationResourceTests: XCTestCase {
  func testOffscreenTurnsReleaseRenderersAndReconstructExactAnswers() async throws {
    let controller = ComposerViewController()
    controller.loadViewIfNeeded()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentViewController = controller
    window.setContentSize(NSSize(width: 560, height: 500))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    controller.configure(context: "历史")
    let firstAnswer = "## 原始回答\n\n保留 **格式**、标点和完整内容。"
    controller.beginRunning(submittedText: "  第一条\n原始消息  ")
    controller.showResult(firstAnswer, status: "已完成")
    _ = controller.preferredPanelHeight(limit: 500)
    weak var firstRenderer = descendants(controller.view).compactMap {
      $0 as? ResultWebRendererView
    }.first
    for index in 1..<60 {
      controller.beginRunning(submittedText: "后续问题 \(index)")
      controller.showResult("回答 \(index)\n\n" + String(repeating: "正文。", count: 60), status: "已完成")
      _ = controller.preferredPanelHeight(limit: 500)
    }
    try await Task.sleep(for: .milliseconds(300))
    if let retained = firstRenderer {
      XCTAssertNil(retained.window)
      XCTAssertEqual(
        descendants(retained).filter { $0 is WKWebView }.count, 0,
        "An AppKit animation may retain a view temporarily, but never its offscreen WebKit resources"
      )
    }
    firstRenderer = nil
    XCTAssertEqual(controller.submittedTurnCount, 60)
    XCTAssertLessThan(descendants(controller.view).filter { $0 is WKWebView }.count, 10)
    let table = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
    table.scrollRowToVisible(0)
    table.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    let renderer = descendants(controller.view).compactMap { $0 as? ResultWebRendererView }
      .first { $0.renderedMarkdownForTesting == firstAnswer }
    XCTAssertNotNil(renderer, "Revisiting history restores exact Markdown from the transcript")
    XCTAssertTrue(controller.isComposerEditable)
    XCTAssertTrue(controller.isComposerVisible)
    controller.configure(context: "新会话")
    XCTAssertEqual(descendants(controller.view).filter { $0 is WKWebView }.count, 0)
  }

  func testTranscriptResourceProbe() async throws {
    guard ProcessInfo.processInfo.environment["MIEN_TRANSCRIPT_PROBE"] == "1" else {
      throw XCTSkip("Opt-in rendered transcript resource probe")
    }
    let controller = ComposerViewController()
    controller.loadViewIfNeeded()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentViewController = controller
    window.setContentSize(NSSize(width: 560, height: 600))
    window.orderFront(nil)
    controller.configure(context: "资源测量")
    let start = ContinuousClock.now
    for index in 0..<24 {
      controller.beginRunning(submittedText: "第 \(index) 轮原始问题")
      controller.showResult(
        "## 第 \(index) 轮回答\n\n" + String(repeating: "正文用于检验长会话的布局与资源生命周期。\n\n", count: 8),
        status: "已完成")
      _ = controller.preferredPanelHeight(limit: 600)
      try await Task.sleep(for: .milliseconds(150))
    }
    try await Task.sleep(for: .seconds(1))
    let views = descendants(controller.view)
    print(
      "TRANSCRIPT_PROBE turns=\(controller.submittedTurnCount) views=\(views.count) webViews=\(views.filter { $0 is WKWebView }.count) elapsed=\(start.duration(to: .now))"
    )
    XCTAssertEqual(controller.submittedTurnCount, 24)
    XCTAssertLessThan(views.filter { $0 is WKWebView }.count, 10)
    controller.configure(context: "重置")
    XCTAssertEqual(descendants(controller.view).filter { $0 is WKWebView }.count, 0)
    window.orderOut(nil)
  }

  private func descendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants($0) }
  }
}
