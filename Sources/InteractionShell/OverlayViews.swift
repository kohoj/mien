import AppKit
import Foundation
import MienContracts

/// Layout values for the transient AppKit panel. Visual appearance is owned by
/// shared native palette, system typeface and AppKit control semantics.
enum OverlayMetrics {
  static let panelWidth = 520.0
  static let cornerRadius = 18.0
  static let padding = 20.0
  static let contentInset = 0.0
  static let topInset = 44.0
  static let bottomInset = 16.0
  static let rowSpacing = 16.0
  static let controlHeight = 32.0
  static let inputPadding = 12.0
  static let composerGap = 16.0
  static let controlHitSize = 28.0
  static let maximumComposerHeight = 96.0
  static let maximumPanelHeight = 580.0

  @MainActor static var resultLineHeight: Double {
    let font = OverlayTypography.response
    return (font.ascender - font.descender + font.leading).rounded(.up)
  }

  /// The compact escape controls are fixed; the conversation owns the rest.
  static func chromeHeight(includesAction: Bool) -> Double {
    topInset + bottomInset
  }
}

/// System typefaces preserve native script fallback; deliberate size/weight
/// relationships distinguish the question, reading surface and input control.
@MainActor
enum OverlayTypography {
  static let user = NSFont.systemFont(ofSize: 13, weight: .medium)
  static let response = NSFont.systemFont(ofSize: 15, weight: .regular)
  static let input = NSFont.systemFont(ofSize: 15, weight: .regular)
  static let activity = NSFont.systemFont(ofSize: 12, weight: .medium)
  static let status = preferred(.callout)
  static let context = NSFont.systemFont(ofSize: 11, weight: .medium)

  private static func preferred(_ style: NSFont.TextStyle) -> NSFont {
    NSFont.preferredFont(forTextStyle: style, options: [:])
  }
}

@MainActor
final class NonactivatingPanel: NSPanel {
  var onCancel: (() -> Void)?
  var onSettings: (() -> Void)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  // Native Window-menu closure must enter the same task cancellation/cleanup
  // boundary as Escape, rather than close an untracked NSPanel directly.
  override func performClose(_ sender: Any?) { onCancel?() }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.charactersIgnoringModifiers == ",", modifiers == .command {
      onSettings?()
      return true
    }
    if event.charactersIgnoringModifiers == "w", modifiers == .command {
      performClose(nil)
      return true
    }
    if event.charactersIgnoringModifiers == "\u{1b}",
      modifiers.subtracting([.capsLock, .numericPad]).isEmpty
    {
      onCancel?()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

@MainActor
final class SemanticLensView: NSBox {
  override func isAccessibilityElement() -> Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    boxType = .custom
    borderWidth = 1
    cornerRadius = 7
    borderColor = .keyboardFocusIndicatorColor
    fillColor = .clear
  }

  required init?(coder: NSCoder) { nil }
}

public enum OverlayPreviewState: String, CaseIterable, Sendable {
  case composing
  case conversation
  case draft
  case undo
  case login
  case failure
}

@MainActor
public enum OverlayPreviewRenderer {
  public static func png(state: OverlayPreviewState, appearance: NSAppearance.Name = .aqua) throws
    -> Data
  {
    let width = OverlayMetrics.panelWidth
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.appearance = NSAppearance(named: appearance)
    window.backgroundColor = .clear
    window.isOpaque = false
    let controller = ComposerViewController()
    window.contentViewController = controller
    window.setContentSize(NSSize(width: width, height: 200))
    controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 200)
    controller.view.layoutSubtreeIfNeeded()
    controller.configure(context: "微信", intent: "这段讨论的结论是什么？")
    switch state {
    case .composing:
      controller.configure(context: "微信", intent: "帮我理清这里的重点")
    case .conversation:
      controller.beginRunning()
      controller.presentActivity(
        AgentActivityPresentation(
          id: "thinking:one",
          kind: .thinking,
          toolName: nil,
          status: .completed
        )
      )
      controller.showResult(
        "先把核心体验做轻。\n\n大家达成了两个共识：**缩短第一次使用的路径**，以及让每一步的结果都清楚可见。\n\n下一步先做一个小范围试用，再决定是否继续扩展。",
        status: "已完成"
      )
      RunLoop.current.run(until: Date().addingTimeInterval(0.85))
      controller.settleMotionForRendering()
      controller.setComposerTextForPreview("帮我写一句回复")
      controller.beginRunning()
      controller.presentActivity(
        AgentActivityPresentation(
          id: "thinking:two",
          kind: .thinking,
          toolName: nil,
          status: .completed
        )
      )
      controller.presentActivity(
        AgentActivityPresentation(
          id: "tool:deployment",
          kind: .tool,
          toolName: "request_context",
          status: .completed
        )
      )
      controller.presentActivity(
        AgentActivityPresentation(
          id: "thinking:two",
          kind: .thinking,
          toolName: nil,
          status: .active
        )
      )
      controller.presentActivity(
        AgentActivityPresentation(
          id: "thinking:two",
          kind: .thinking,
          toolName: nil,
          status: .completed
        )
      )
      controller.presentActivity(
        AgentActivityPresentation(
          id: "tool:verify",
          kind: .tool,
          toolName: "submit_outcome",
          status: .completed
        )
      )
      controller.showResult(
        "赞同。先让一个完整的体验成立，再根据真实使用反馈往前走。",
        status: "已完成"
      )
      RunLoop.current.run(until: Date().addingTimeInterval(0.48))
      controller.settleMotionForRendering()
      controller.showCaretForPreview()
    case .draft, .undo:
      controller.beginRunning(submittedText: "帮我婉拒这次邀请")
      controller.presentActivity(
        AgentActivityPresentation(
          id: "thinking",
          kind: .thinking,
          toolName: nil,
          status: .completed
        )
      )
      controller.presentActivity(
        AgentActivityPresentation(
          id: "tool:context",
          kind: .tool,
          toolName: "request_context",
          status: .completed
        )
      )
      controller.setContextDisclosure("对话 · 辅助功能 + 长图 · Codex 将使用")
      controller.showResult(
        "感谢你的理解和信任，不过这个时间我可能不太合适参与。希望下次有更合适的机会，再一起合作。",
        status: state == .draft ? "草稿已生成" : "已插入 · 可撤销",
        action: state == .draft ? .insertDraft : .undoDraft
      )
      // Let the same completion animation used in the live product settle so
      // the preview captures the final icon-only process state.
      RunLoop.current.run(until: Date().addingTimeInterval(0.85))
      controller.settleMotionForRendering()
    case .login:
      controller.beginRunning()
      controller.showActionPrompt(status: "登录后继续当前任务", action: .loginCodex)
      controller.settleMotionForRendering()
    case .failure:
      controller.beginRunning()
      controller.presentActivity(
        AgentActivityPresentation(
          id: "tool:context",
          kind: .tool,
          toolName: "request_context",
          status: .failed
        )
      )
      controller.setStatus("无法读取更早的内容", allowsRetry: true)
      controller.settleMotionForRendering()
      RunLoop.current.run(until: Date().addingTimeInterval(0.30))
    }

    let size = NSSize(
      width: width,
      height: controller.preferredPanelHeight(limit: 600)
    )
    window.setContentSize(size)
    controller.view.frame = NSRect(origin: .zero, size: size)
    window.layoutIfNeeded()
    controller.view.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    // Resizing can bring a reused historical row into view and start a fresh
    // WebKit load. Snapshot only after the real visible typesetters are ready.
    let deadline = Date().addingTimeInterval(4)
    func renderers(in view: NSView) -> [ResultWebRendererView] {
      view.subviews.flatMap { child in
        (child as? ResultWebRendererView).map { [$0] } ?? renderers(in: child)
      }
    }
    while renderers(in: controller.view).contains(where: { !$0.isReadyForSnapshot }) {
      guard Date() < deadline else { throw CocoaError(.coderValueNotFound) }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      controller.view.layoutSubtreeIfNeeded()
    }
    window.displayIfNeeded()
    guard
      let representation = controller.view.bitmapImageRepForCachingDisplay(
        in: controller.view.bounds
      )
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    controller.view.cacheDisplay(in: controller.view.bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    return data
  }
}

@MainActor
public final class OverlayCoordinator {
  public var onSettings: (() -> Void)?
  public var onSubmit: ((String, InvocationSnapshot) -> Void)?
  public var onDismiss: (() -> Void)?
  public var onResultAction: ((TaskPresentationAction) -> Void)?

  private let lensPanel: NonactivatingPanel
  private let composerPanel: NonactivatingPanel
  private let composerController: ComposerViewController
  private let transformer = CoordinateTransformer()
  private var resizeScheduled = false
  private let placement = PanelPlacement()
  private var snapshot: InvocationSnapshot?
  private var boundTaskID: UUID?
  private var lastPresentationSequence: UInt64?
  private let compactSize = NSSize(
    width: OverlayMetrics.panelWidth,
    height: OverlayMetrics.chromeHeight(includesAction: false) + OverlayMetrics.controlHeight
      + OverlayMetrics.inputPadding
  )

  public convenience init() {
    self.init(composerController: ComposerViewController())
  }

  init(composerController: ComposerViewController) {
    self.composerController = composerController
    lensPanel = NonactivatingPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    lensPanel.backgroundColor = .clear
    lensPanel.isOpaque = false
    lensPanel.hasShadow = false
    lensPanel.ignoresMouseEvents = true
    lensPanel.level = .statusBar
    lensPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    lensPanel.contentView = SemanticLensView()

    composerPanel = NonactivatingPanel(
      contentRect: NSRect(origin: .zero, size: compactSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    composerPanel.backgroundColor = .clear
    composerPanel.isOpaque = false
    composerPanel.hasShadow = true
    composerPanel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    composerPanel.becomesKeyOnlyIfNeeded = true
    composerPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    composerPanel.contentViewController = composerController
    composerPanel.setContentSize(compactSize)
    composerPanel.onSettings = { [weak self] in self?.onSettings?() }
    composerPanel.title = "上下文操作"
    composerPanel.setAccessibilityLabel("上下文操作")
    composerPanel.onCancel = { [weak self] in self?.dismiss() }

    composerController.onCancel = { [weak self] in self?.dismiss() }
    composerController.onResultAction = { [weak self] action in
      self?.onResultAction?(action)
    }
    composerController.onSubmit = { [weak self] intent in
      guard let self, let snapshot = self.snapshot else { return }
      self.onSubmit?(intent, snapshot)
    }
    composerController.onContentSizeChange = { [weak self] in
      guard let self, self.composerPanel.isVisible, !self.resizeScheduled else { return }
      self.resizeScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.resizeScheduled = false
        guard self.composerPanel.isVisible else { return }
        self.resizeToFitConversation()
      }
    }
  }

  public var isVisible: Bool { composerPanel.isVisible }
  public var hasSession: Bool { snapshot != nil }

  public func show(snapshot: InvocationSnapshot) throws {
    self.snapshot = snapshot
    boundTaskID = nil
    lastPresentationSequence = nil
    composerController.configure(context: accessibilityContext(for: snapshot))

    let displayID = snapshot.environment.displayID
    let screens = ScreenGeometry.current
    guard let screen = screens.first(where: { $0.displayID == displayID }) else {
      throw CoordinateTransformerError.displayUnavailable(displayID)
    }
    let sourceRect = snapshot.pointedElement?.frame ?? snapshot.window.frame
    let targetRect = try transformer.appKitRect(
      from: sourceRect,
      displayID: displayID,
      screens: screens
    )
    let pointer = try transformer.appKitPoint(
      from: snapshot.environment.pointer,
      displayID: displayID,
      screens: screens
    )
    let lensFrame = targetRect.insetBy(dx: -4, dy: -4)
    lensPanel.setFrame(lensFrame, display: false)

    let initialSize = NSSize(
      width: OverlayMetrics.panelWidth,
      height: composerController.preferredPanelHeight(
        limit: max(
          compactSize.height,
          min(OverlayMetrics.maximumPanelHeight, screen.visibleFrame.height * 0.62)
        )
      )
    )
    composerPanel.setContentSize(initialSize)
    let composerFrame = placement.place(
      panelSize: initialSize,
      pointer: pointer,
      targetRect: lensFrame,
      visibleFrame: screen.visibleFrame
    )
    composerPanel.setFrame(composerFrame, display: false)

    lensPanel.alphaValue = 0
    composerPanel.alphaValue = 0
    lensPanel.orderFrontRegardless()
    composerPanel.makeKeyAndOrderFront(nil)
    composerPanel.displayIfNeeded()
    composerPanel.invalidateShadow()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      lensPanel.animator().alphaValue = 1
      composerPanel.animator().alphaValue = 1
    }
    composerController.focusInput()
  }

  public func dismiss(notify: Bool = true) {
    let wasVisible = isVisible
    snapshot = nil
    boundTaskID = nil
    lastPresentationSequence = nil
    lensPanel.orderOut(nil)
    composerPanel.orderOut(nil)
    if notify, wasVisible { onDismiss?() }
  }

  public func detach() {
    guard hasSession else { return }
    lensPanel.orderOut(nil)
    composerPanel.orderOut(nil)
  }

  public func restore() {
    guard hasSession else { return }
    lensPanel.orderFrontRegardless()
    composerPanel.makeKeyAndOrderFront(nil)
    resizeToFitConversation()
    composerController.focusInput()
  }

  public func setStatus(_ text: String, allowsRetry: Bool = false) {
    guard hasSession else { return }
    composerController.setStatus(text, allowsRetry: allowsRetry)
  }

  public func invalidateConversation(status: String) {
    guard isVisible else {
      dismiss(notify: false)
      return
    }
    boundTaskID = nil
    lastPresentationSequence = nil
    snapshot = nil
    composerController.invalidateConversation(status: status)
  }

  public func bind(taskID: UUID) {
    guard isVisible else { return }
    boundTaskID = taskID
    lastPresentationSequence = nil
    composerController.bind(taskID: taskID)
  }

  public func presentActivity(_ presentation: AgentActivityPresentation) {
    guard hasSession else { return }
    composerController.presentActivity(presentation)
  }

  public func setContextDisclosure(_ disclosure: String) {
    guard hasSession else { return }
    composerController.setContextDisclosure(disclosure)
  }

  public func present(_ presentation: TaskPresentation) {
    guard isVisible, boundTaskID == presentation.taskID else { return }
    if let lastPresentationSequence, presentation.sequence <= lastPresentationSequence { return }
    lastPresentationSequence = presentation.sequence
    if let result = presentation.result {
      showResult(
        result,
        status: presentation.status,
        action: presentation.action,
        outcome: presentation.outcome
      )
    } else if let action = presentation.action {
      showActionPrompt(status: presentation.status, action: action)
    } else {
      composerController.setStatus(
        presentation.status,
        allowsRetry: presentation.allowsRetry
      )
    }
  }

  public func showResult(
    _ text: String,
    status: String = "已完成",
    action: TaskPresentationAction? = nil,
    outcome: TaskPresentationOutcome = .success
  ) {
    guard hasSession else { return }
    composerController.showResult(text, status: status, action: action, tone: outcome)
    composerController.setResultActionEnabled(true)
  }

  public func showActionPrompt(status: String, action: TaskPresentationAction) {
    guard hasSession else { return }
    composerController.showActionPrompt(status: status, action: action)
    composerController.setResultActionEnabled(true)
  }

  public func resumeAfterAuthentication() {
    guard hasSession else { return }
    boundTaskID = nil
    lastPresentationSequence = nil
    if composerController.resumeAfterAuthentication() { restore() }
  }

  /// Grows with the transcript until 62% of the active screen, then keeps the
  /// conversation scrollable. Its top edge stays fixed so the panel never
  /// jumps away from the user as a turn unfolds.
  private func resizeToFitConversation() {
    let previousFrame = composerPanel.frame
    let screens = ScreenGeometry.current
    let visibleFrame =
      screens.first(where: { $0.appKitFrame.intersects(previousFrame) })?.visibleFrame
      ?? NSScreen.main?.visibleFrame
      ?? previousFrame
    let height = composerController.preferredPanelHeight(
      limit: max(
        compactSize.height,
        min(OverlayMetrics.maximumPanelHeight, visibleFrame.height * 0.62)
      )
    )
    let expandedFrame = NSRect(
      x: previousFrame.minX,
      y: previousFrame.maxY - height,
      width: OverlayMetrics.panelWidth,
      height: height
    )
    composerPanel.setFrame(
      placement.clamp(expandedFrame, toVisibleFrame: visibleFrame),
      display: true,
      animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    )
    composerPanel.invalidateShadow()
  }

  /// Names only the target application in the header and assistive technology. Actual
  /// evidence scope remains unknown until the Agent requests it and the Host
  /// records a manifest.
  private func accessibilityContext(for snapshot: InvocationSnapshot) -> String {
    NSRunningApplication(
      processIdentifier: snapshot.window.processIdentifier
    )?.localizedName ?? snapshot.window.bundleIdentifier
  }
}
