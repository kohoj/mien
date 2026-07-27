import AppKit
import Foundation
import MienContracts

@MainActor
final class NonactivatingPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class SemanticLensView: NSView {
  override var isFlipped: Bool { true }

  override func isAccessibilityElement() -> Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let path = NSBezierPath(
      roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
      xRadius: 9,
      yRadius: 9
    )
    path.lineWidth = 1.25
    NSColor.controlAccentColor.withAlphaComponent(0.88).setStroke()
    path.stroke()
  }
}

@MainActor
final class ComposerViewController: NSViewController, NSTextFieldDelegate {
  var onSubmit: ((String) -> Void)?
  var onCancel: (() -> Void)?
  var onResultAction: ((TaskPresentationAction) -> Void)?

  private let intentField = NSTextField()
  private let submitButton = NSButton()
  private let contextLabel = NSTextField(labelWithString: "")
  private let statusLabel = NSTextField(labelWithString: "")
  private let resultLabel = NSTextField(labelWithString: "")
  private let resultActionButton = NSButton()
  private var acceptsSubmission = true
  private var baseContext = ""
  private var resultAction: TaskPresentationAction?
  private var resultHeightConstraint: NSLayoutConstraint?

  override func loadView() {
    let effect = NSVisualEffectView()
    effect.material = .hudWindow
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = 13
    effect.layer?.cornerCurve = .continuous
    effect.layer?.borderWidth = 0.5
    effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor

    intentField.placeholderString = "想让它做什么？"
    intentField.font = .systemFont(ofSize: 14.5, weight: .regular)
    intentField.textColor = .labelColor
    intentField.backgroundColor = NSColor.black.withAlphaComponent(0.16)
    intentField.isBezeled = true
    intentField.bezelStyle = .roundedBezel
    intentField.focusRingType = .default
    intentField.delegate = self
    intentField.translatesAutoresizingMaskIntoConstraints = false
    intentField.setAccessibilityLabel("操作意图")
    intentField.setAccessibilityHelp("输入希望 Codex 对当前内容完成的任务")

    submitButton.bezelStyle = .circular
    submitButton.controlSize = .large
    submitButton.image = NSImage(
      systemSymbolName: "arrow.turn.down.left",
      accessibilityDescription: "运行"
    )
    submitButton.imagePosition = .imageOnly
    submitButton.bezelColor = .systemBlue
    submitButton.contentTintColor = .white
    submitButton.target = self
    submitButton.action = #selector(submitIntent)
    submitButton.isEnabled = false
    submitButton.translatesAutoresizingMaskIntoConstraints = false
    submitButton.setAccessibilityLabel("运行")
    submitButton.setAccessibilityHelp("使用当前授权上下文运行输入的任务")

    contextLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
    contextLabel.textColor = .secondaryLabelColor
    contextLabel.lineBreakMode = .byTruncatingMiddle
    contextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    contextLabel.translatesAutoresizingMaskIntoConstraints = false
    contextLabel.setAccessibilityLabel("当前上下文")

    statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
    statusLabel.textColor = .tertiaryLabelColor
    statusLabel.alignment = .right
    statusLabel.lineBreakMode = .byTruncatingHead
    statusLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.setAccessibilityLabel("任务状态")

    resultLabel.font = .systemFont(ofSize: 13.5, weight: .regular)
    resultLabel.textColor = .labelColor
    resultLabel.maximumNumberOfLines = 4
    resultLabel.lineBreakMode = .byTruncatingTail
    resultLabel.preferredMaxLayoutWidth = 366
    resultLabel.cell?.wraps = true
    resultLabel.cell?.usesSingleLineMode = false
    resultLabel.isSelectable = true
    resultLabel.isHidden = true
    resultLabel.translatesAutoresizingMaskIntoConstraints = false
    resultLabel.setAccessibilityLabel("Codex 结果")

    resultActionButton.bezelStyle = .rounded
    resultActionButton.controlSize = .large
    resultActionButton.font = .systemFont(ofSize: 12.5, weight: .semibold)
    resultActionButton.target = self
    resultActionButton.action = #selector(performResultAction)
    resultActionButton.keyEquivalent = "\r"
    resultActionButton.keyEquivalentModifierMask = [.command]
    resultActionButton.isHidden = true
    resultActionButton.translatesAutoresizingMaskIntoConstraints = false

    let metadata = NSStackView(views: [contextLabel, statusLabel])
    metadata.orientation = .horizontal
    metadata.alignment = .centerY
    metadata.distribution = .fill
    metadata.spacing = 8
    metadata.translatesAutoresizingMaskIntoConstraints = false

    let actionRow = NSStackView(views: [NSView(), resultActionButton])
    actionRow.orientation = .horizontal
    actionRow.alignment = .centerY
    actionRow.distribution = .fill
    actionRow.translatesAutoresizingMaskIntoConstraints = false

    let inputRow = NSStackView(views: [intentField, submitButton])
    inputRow.orientation = .horizontal
    inputRow.alignment = .centerY
    inputRow.distribution = .fill
    inputRow.spacing = 7
    inputRow.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [inputRow, resultLabel, actionRow, metadata])
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(stack)
    let resultHeightConstraint = resultLabel.heightAnchor.constraint(
      greaterThanOrEqualToConstant: 48
    )
    resultHeightConstraint.priority = .defaultHigh
    self.resultHeightConstraint = resultHeightConstraint
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 11),
      stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10),
      inputRow.heightAnchor.constraint(equalToConstant: 34),
      submitButton.widthAnchor.constraint(equalToConstant: 30),
      submitButton.heightAnchor.constraint(equalToConstant: 30),
      resultActionButton.heightAnchor.constraint(equalToConstant: 30),
      resultActionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 118),
      contextLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
    ])
    view = effect
  }

  func configure(context: String, intent: String = "") {
    acceptsSubmission = true
    intentField.isEditable = true
    intentField.stringValue = intent
    submitButton.isEnabled = !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    baseContext = context
    contextLabel.stringValue = context
    statusLabel.stringValue = "Return 运行"
    resultLabel.stringValue = ""
    resultLabel.isHidden = true
    resultHeightConstraint?.isActive = false
    resultAction = nil
    resultActionButton.isHidden = true
  }

  func setContextDisclosure(_ disclosure: String) {
    contextLabel.stringValue = "\(baseContext) · \(disclosure)"
    contextLabel.setAccessibilityValue(contextLabel.stringValue)
    NSAccessibility.post(element: contextLabel, notification: .valueChanged)
  }

  func focusInput() {
    view.window?.makeFirstResponder(intentField)
  }

  func setStatus(_ text: String, allowsRetry: Bool = false) {
    statusLabel.stringValue = text
    statusLabel.setAccessibilityValue(text)
    NSAccessibility.post(element: statusLabel, notification: .valueChanged)
    if allowsRetry {
      acceptsSubmission = true
      intentField.isEditable = true
      submitButton.isEnabled = !intentField.stringValue.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
      focusInput()
    }
  }

  func beginRunning() {
    acceptsSubmission = false
    intentField.isEditable = false
    submitButton.isEnabled = false
    setStatus("上下文已冻结")
  }

  func showResult(
    _ text: String,
    status: String,
    action: TaskPresentationAction? = nil
  ) {
    resultLabel.stringValue = text
    resultLabel.isHidden = false
    resultHeightConstraint?.isActive = true
    resultAction = action
    switch action {
    case .insertDraft:
      resultActionButton.title = "插入原输入框"
      resultActionButton.bezelColor = .systemBlue
      resultActionButton.contentTintColor = .white
      resultActionButton.toolTip = "仅写入草稿，不会发送（⌘Return）"
      resultActionButton.setAccessibilityLabel("插入原输入框")
      resultActionButton.setAccessibilityHelp("把草稿写入原输入框，但不会发送")
      resultActionButton.isHidden = false
    case .undoDraft:
      resultActionButton.title = "撤销插入"
      resultActionButton.bezelColor = nil
      resultActionButton.contentTintColor = .labelColor
      resultActionButton.toolTip = "仅当输入框未被继续修改时恢复原内容（⌘Return）"
      resultActionButton.setAccessibilityLabel("撤销插入")
      resultActionButton.setAccessibilityHelp("输入框未被继续修改时恢复插入前内容")
      resultActionButton.isHidden = false
    case .loginCodex:
      resultActionButton.title = "登录 Codex"
      resultActionButton.bezelColor = .systemBlue
      resultActionButton.contentTintColor = .white
      resultActionButton.toolTip = "使用 ChatGPT 账户完成设备授权（⌘Return）"
      resultActionButton.setAccessibilityLabel("登录 Codex")
      resultActionButton.setAccessibilityHelp("在浏览器中完成 Codex 设备授权")
      resultActionButton.isHidden = false
    case nil:
      resultActionButton.isHidden = true
    }
    statusLabel.stringValue = status
    statusLabel.setAccessibilityValue(status)
    NSAccessibility.post(element: resultLabel, notification: .valueChanged)
  }

  @objc private func performResultAction() {
    guard let resultAction else { return }
    resultActionButton.isEnabled = false
    onResultAction?(resultAction)
  }

  @objc private func submitIntent() {
    let text = intentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard acceptsSubmission, !text.isEmpty else { return }
    onSubmit?(text)
  }

  func controlTextDidChange(_ notification: Notification) {
    submitButton.isEnabled =
      acceptsSubmission
      && !intentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func setResultActionEnabled(_ enabled: Bool) {
    resultActionButton.isEnabled = enabled
  }

  func showActionPrompt(status: String, action: TaskPresentationAction) {
    resultLabel.stringValue = ""
    resultLabel.isHidden = true
    showResult("", status: status, action: action)
    resultLabel.isHidden = true
    resultHeightConstraint?.isActive = false
  }

  func control(
    _ control: NSControl,
    textView: NSTextView,
    doCommandBy commandSelector: Selector
  ) -> Bool {
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      onCancel?()
      return true
    }
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      let text = intentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard acceptsSubmission, !text.isEmpty, !textView.hasMarkedText() else { return true }
      submitIntent()
      return true
    }
    return false
  }
}

public enum OverlayPreviewState: String, CaseIterable, Sendable {
  case composing
  case draft
  case undo
  case login
}

@MainActor
public enum OverlayPreviewRenderer {
  public static func png(state: OverlayPreviewState) throws -> Data {
    let height: CGFloat =
      switch state {
      case .composing: 86
      case .draft, .undo: 194
      case .login: 126
      }
    let size = NSSize(width: 390, height: height)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = .clear
    window.isOpaque = false
    let controller = ComposerViewController()
    window.contentViewController = controller
    controller.configure(context: "微信 · 当前对话", intent: "结合前文，帮我礼貌拒绝")
    switch state {
    case .composing:
      break
    case .draft:
      controller.beginRunning()
      controller.setContextDisclosure("对话 · 辅助功能 + 长图 · Codex 将使用")
      controller.showResult(
        "感谢你的理解和信任，不过这个时间我可能不太合适参与。希望下次有更合适的机会，再一起合作。",
        status: "草稿已生成",
        action: .insertDraft
      )
    case .undo:
      controller.beginRunning()
      controller.setContextDisclosure("对话 · 辅助功能 + 长图 · Codex 将使用")
      controller.showResult(
        "感谢你的理解和信任，不过这个时间我可能不太合适参与。希望下次有更合适的机会，再一起合作。",
        status: "已插入 · 可撤销",
        action: .undoDraft
      )
    case .login:
      controller.beginRunning()
      controller.showActionPrompt(status: "登录后继续当前任务", action: .loginCodex)
    }

    window.setContentSize(size)
    controller.view.frame = NSRect(origin: .zero, size: size)
    window.layoutIfNeeded()
    controller.view.layoutSubtreeIfNeeded()
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
  public var onSubmit: ((String, InvocationSnapshot) -> Void)?
  public var onDismiss: (() -> Void)?
  public var onResultAction: ((TaskPresentationAction) -> Void)?

  private let lensPanel: NonactivatingPanel
  private let composerPanel: NonactivatingPanel
  private let composerController = ComposerViewController()
  private let transformer = CoordinateTransformer()
  private let placement = PanelPlacement()
  private var snapshot: InvocationSnapshot?
  private var boundTaskID: UUID?
  private var lastPresentationSequence: UInt64?
  private let compactSize = NSSize(width: 390, height: 86)

  public init() {
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
    lensPanel.level = .floating
    lensPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    lensPanel.contentView = SemanticLensView()

    composerPanel = NonactivatingPanel(
      contentRect: NSRect(x: 0, y: 0, width: 390, height: 84),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    composerPanel.backgroundColor = .clear
    composerPanel.isOpaque = false
    composerPanel.hasShadow = true
    composerPanel.level = .floating
    composerPanel.becomesKeyOnlyIfNeeded = true
    composerPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    composerPanel.contentViewController = composerController
    composerPanel.title = "上下文操作"
    composerPanel.setAccessibilityLabel("上下文操作")

    composerController.onCancel = { [weak self] in self?.dismiss() }
    composerController.onResultAction = { [weak self] action in
      self?.onResultAction?(action)
    }
    composerController.onSubmit = { [weak self] intent in
      guard let self, let snapshot = self.snapshot else { return }
      self.composerController.beginRunning()
      self.onSubmit?(intent, snapshot)
    }
  }

  public var isVisible: Bool { composerPanel.isVisible }
  public var hasSession: Bool { snapshot != nil }

  public func show(snapshot: InvocationSnapshot) throws {
    self.snapshot = snapshot
    boundTaskID = nil
    lastPresentationSequence = nil
    composerPanel.setContentSize(compactSize)
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

    let composerFrame = placement.place(
      panelSize: composerPanel.frame.size,
      pointer: pointer,
      targetRect: lensFrame,
      visibleFrame: screen.visibleFrame
    )
    composerPanel.setFrame(composerFrame, display: false)
    composerController.configure(context: contextLabel(for: snapshot))

    lensPanel.alphaValue = 0
    composerPanel.alphaValue = 0
    lensPanel.orderFrontRegardless()
    composerPanel.makeKeyAndOrderFront(nil)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
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
    composerController.focusInput()
  }

  public func setStatus(_ text: String, allowsRetry: Bool = false) {
    guard isVisible else { return }
    composerController.setStatus(text, allowsRetry: allowsRetry)
  }

  public func bind(taskID: UUID) {
    guard isVisible else { return }
    boundTaskID = taskID
    lastPresentationSequence = nil
  }

  public func setContextDisclosure(_ disclosure: String) {
    guard isVisible else { return }
    composerController.setContextDisclosure(disclosure)
  }

  public func present(_ presentation: TaskPresentation) {
    guard isVisible, boundTaskID == presentation.taskID else { return }
    if let lastPresentationSequence, presentation.sequence <= lastPresentationSequence { return }
    lastPresentationSequence = presentation.sequence
    if let result = presentation.result {
      showResult(result, status: presentation.status, action: presentation.action)
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
    action: TaskPresentationAction? = nil
  ) {
    guard isVisible else { return }
    let previousFrame = composerPanel.frame
    let height = action == nil ? 154.0 : 194.0
    let screens = ScreenGeometry.current
    let visibleFrame =
      screens.first(where: { $0.appKitFrame.intersects(previousFrame) })?.visibleFrame
      ?? NSScreen.main?.visibleFrame
      ?? previousFrame
    let expandedFrame = NSRect(
      x: previousFrame.minX,
      y: previousFrame.maxY - height,
      width: previousFrame.width,
      height: height
    )
    let clampedFrame = placement.clamp(expandedFrame, toVisibleFrame: visibleFrame)
    composerPanel.setFrame(
      clampedFrame,
      display: true,
      animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    )
    composerController.setResultActionEnabled(true)
    composerController.showResult(text, status: status, action: action)
  }

  public func showActionPrompt(status: String, action: TaskPresentationAction) {
    guard isVisible else { return }
    let previousFrame = composerPanel.frame
    let height = 126.0
    let screens = ScreenGeometry.current
    let visibleFrame =
      screens.first(where: { $0.appKitFrame.intersects(previousFrame) })?.visibleFrame
      ?? NSScreen.main?.visibleFrame
      ?? previousFrame
    let expandedFrame = NSRect(
      x: previousFrame.minX,
      y: previousFrame.maxY - height,
      width: previousFrame.width,
      height: height
    )
    composerPanel.setFrame(
      placement.clamp(expandedFrame, toVisibleFrame: visibleFrame),
      display: true,
      animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    )
    composerController.setResultActionEnabled(true)
    composerController.showActionPrompt(status: status, action: action)
  }

  private func contextLabel(for snapshot: InvocationSnapshot) -> String {
    let application =
      NSRunningApplication(
        processIdentifier: snapshot.window.processIdentifier
      )?.localizedName ?? snapshot.window.bundleIdentifier
    let scope = snapshot.pointedElement == nil ? "当前窗口" : "指向内容"
    return "\(application) · \(scope)"
  }
}
