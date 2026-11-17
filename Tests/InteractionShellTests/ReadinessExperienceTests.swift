import AppKit
import InvocationKernel
import MienContracts
import PermissionKernel
import XCTest

@testable import InteractionShell

@MainActor
final class ReadinessExperienceTests: XCTestCase {
  func testOptionalCaptureDoesNotDelayFirstUse() {
    let state = snapshot(agent: .connected(agentName: "已连接"), accessibility: .authorized)
    XCTAssertTrue(state.canUse)
    XCTAssertFalse(state.isFullyReady)
    XCTAssertEqual(state.nextAction, .finish)
    XCTAssertEqual(MienSetupPresentation(state).action, "开始使用")
  }

  func testBrowserAuthorizationShowsExactCodeAndWaitsForVerifiedConnection() {
    let state = snapshot(agent: .awaitingAuthorization(code: "ABCD-EFGH"))
    let presentation = MienSetupPresentation(state)
    XCTAssertEqual(presentation.code, "ABCD-EFGH")
    XCTAssertTrue(presentation.busy)
    XCTAssertFalse(state.canUse)
    XCTAssertEqual(state.nextAction, .wait)
  }

  func testSettingsCanSelectAnUnchangedCatalogAfterReconnection() throws {
    let controller = MienSettingsViewController(actions: .preview)
    controller.apply(snapshot(agent: .connected(agentName: "已连接")))
    let picker = try XCTUnwrap(
      descendants(controller.view).compactMap { $0 as? AgentModelPicker }.first)
    XCTAssertTrue(picker.isEnabled)
    controller.apply(snapshot(agent: .connecting))
    XCTAssertFalse(picker.isEnabled)
    controller.apply(snapshot(agent: .connected(agentName: "已连接")))
    XCTAssertTrue(picker.isEnabled)
  }

  func testMenuExposesSetupAndSettingsWithoutClaimingReadiness() {
    let menu = TaskCenterController()
    let items = menu.makeMenuItems()
    XCTAssertEqual(items.first?.title, "完成设置…")
    XCTAssertTrue(items.contains { $0.title == "设置…" && $0.keyEquivalent == "," })
    menu.setReady(true)
    XCTAssertTrue(menu.makeMenuItems().first?.title.hasPrefix("对当前窗口提问") == true)
    menu.show(status: "需要重新连接", completed: true)
    XCTAssertEqual(menu.makeMenuItems().first?.title, "继续对话")
    XCTAssertTrue(menu.makeMenuItems().contains { $0.title == "需要重新连接" })
    menu.hide()
    menu.setReady(false)
    XCTAssertEqual(menu.makeMenuItems().first?.title, "完成设置…")
    menu.hasConversation = { true }
    XCTAssertEqual(menu.makeMenuItems().first?.title, "继续对话")
  }

  func testInvocationFailureHasActionableTypedFeedback() {
    XCTAssertTrue(
      InvocationFeedback.message(for: InvocationResolutionError.noWindowAtPointer).contains(
        "打开一个应用窗口"))
    XCTAssertTrue(
      InvocationFeedback.message(for: InvocationResolutionError.targetChanged).contains("窗口已变化"))
    XCTAssertTrue(
      InvocationFeedback.message(for: InvocationResolutionError.invalidPointer).contains("光标"))
  }

  func testSettingsShortcutWorksInTheNonactivatingPanel() throws {
    let panel = NonactivatingPanel(
      contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    var opened = false
    panel.onSettings = { opened = true }
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero,
        modifierFlags: .command, timestamp: 0, windowNumber: panel.windowNumber,
        context: nil, characters: ",", charactersIgnoringModifiers: ",", isARepeat: false,
        keyCode: 43))
    XCTAssertTrue(panel.performKeyEquivalent(with: event))
    XCTAssertTrue(opened)
  }

  func testWindowCloseShortcutUsesConversationCleanup() throws {
    let panel = NonactivatingPanel(
      contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    var cancellations = 0
    panel.onCancel = { cancellations += 1 }
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: panel.windowNumber, context: nil, characters: "w",
        charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
    XCTAssertTrue(panel.performKeyEquivalent(with: event))
    XCTAssertEqual(cancellations, 1)
    panel.performClose(nil)
    XCTAssertEqual(cancellations, 2)
  }

  private func snapshot(
    agent: AgentConnectionReadiness,
    accessibility: DesktopPermissionStatus = .deniedOrNotRequested
  ) -> MienReadinessSnapshot {
    MienReadinessSnapshot(
      agent: agent,
      models: .available(
        catalog: AgentModelCatalog(
          currentModelID: "test-model",
          options: [AgentModelOption(id: "test-model", name: "Test model")]), preferredModelID: nil),
      permissions: DesktopPermissionReadiness(
        accessibility: accessibility,
        screenRecording: .deniedOrNotRequested))
  }

  private func descendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants($0) }
  }
}
