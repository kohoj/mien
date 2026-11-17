import AppKit
import Foundation
import MienContracts
import QuartzCore

@MainActor
private final class ConversationMaterialView: NSVisualEffectView {
  private let paper = MienPaperView()

  private static let roundedWindowMask: NSImage = {
    let radius = OverlayMetrics.cornerRadius
    let edge = radius * 2 + 2
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
      NSColor.white.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    material = .contentBackground
    blendingMode = .withinWindow
    state = .followsWindowActiveState
    // A layer corner clips the material but does not describe a transparent
    // window's silhouette to AppKit's window-shadow compositor. maskImage is
    // the AppKit-owned path for keeping both the material and native shadow on
    // the same rounded shape.
    maskImage = Self.roundedWindowMask
    wantsLayer = true
    layer?.cornerRadius = OverlayMetrics.cornerRadius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    paper.frame = bounds
    paper.autoresizingMask = [.width, .height]
    addSubview(paper)
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class ComposerInputTextView: NSTextView {
  var onInputStateChange: (() -> Void)?

  override func setMarkedText(
    _ string: Any,
    selectedRange: NSRange,
    replacementRange: NSRange
  ) {
    super.setMarkedText(
      string,
      selectedRange: selectedRange,
      replacementRange: replacementRange
    )
    onInputStateChange?()
  }

  override func unmarkText() {
    super.unmarkText()
    onInputStateChange?()
  }
}

/// A titlebar-sized, non-semantic AppKit drag affordance. Keeping the region
/// as a real view lets AppKit hand the gesture to Window Server while the
/// adjacent controls and conversation content retain their normal hit testing.
@MainActor
final class WindowDragRegionView: NSView {
  override var mouseDownCanMoveWindow: Bool { true }

  override func isAccessibilityElement() -> Bool { false }

  override func mouseDown(with event: NSEvent) {
    window?.performDrag(with: event)
  }
}

@MainActor
final class ComposerViewController: NSViewController, NSTextViewDelegate {
  var onSubmit: ((String) -> Void)?
  var onCancel: (() -> Void)?
  var onResultAction: ((TaskPresentationAction) -> Void)?
  var onContentSizeChange: (() -> Void)?

  private let intentTextView = ComposerInputTextView()
  private let inputScrollView = NSScrollView()
  private let placeholderLabel = NSTextField(labelWithString: "对当前窗口提问…")
  private let contextLabel = NSTextField(labelWithString: "")
  private let previewCaret = NSView()
  private let submitButton = MienAccentButton()
  private let composerRow = NSStackView()
  private var composerSurface: NSView!
  private let transcript = ConversationTranscriptView()
  private let bodyStack = NSStackView()
  private var scrollHeightConstraint: NSLayoutConstraint?
  private var composerHeightConstraint: NSLayoutConstraint?
  private var acceptsSubmission = true
  private var activeTurn: ConversationTurn?
  private var lastTurn: ConversationTurn?
  private var turnsByTaskID: [UUID: ConversationTurn] = [:]
  private var boundTaskID: UUID?
  private var accessibilityContext = ""
  private var accessibilityDisclosure: String?

  var submittedTurnCount: Int { transcript.turns.count }
  var submittedTurnsAreImmutable: Bool { true }  // userText is immutable in the transcript model.
  var isComposerVisible: Bool { !composerSurface.isHidden }
  var isComposerEditable: Bool { intentTextView.isEditable }
  private var lastTurnView: ConversationTurnView? { lastTurn.flatMap { transcript.view(for: $0) } }
  var completedProcessUsesText: Bool { lastTurnView?.collapsedProcessUsesText ?? false }
  var hasCollapsedProcessSymbol: Bool { lastTurnView?.hasCollapsedProcessSymbol ?? false }
  var visibleTerminalStatus: String? { lastTurnView?.visibleTerminalStatus }
  var visibleActivityCount: Int { lastTurnView?.visibleActivityCount ?? 0 }
  var visibleActivityTitles: [String] { lastTurnView?.visibleActivityTitles ?? [] }
  var processAccessibilityLabel: String? { lastTurnView?.processAccessibilityLabel }
  var lastSubmittedText: String? { lastTurn?.userText }
  var isRetryVisible: Bool { lastTurnView?.retryControlIsVisible ?? false }
  var composerText: String { intentTextView.string }
  var closeKeyEquivalent: String { "\u{1b}" }
  var hasRoundedWindowMask: Bool { (view as? NSVisualEffectView)?.maskImage != nil }
  var isPlaceholderVisible: Bool { !placeholderLabel.isHidden }

  override func loadView() {
    let surface = ConversationMaterialView(
      frame: NSRect(
        x: 0, y: 0, width: OverlayMetrics.panelWidth,
        height: OverlayMetrics.chromeHeight(includesAction: false)
          + OverlayMetrics.controlHeight + OverlayMetrics.inputPadding))

    let escapeLabel = NSTextField(labelWithString: "esc")
    escapeLabel.font = OverlayTypography.context
    escapeLabel.textColor = .tertiaryLabelColor
    escapeLabel.setAccessibilityElement(false)

    let closeButton = NSButton()
    closeButton.bezelStyle = .accessoryBarAction
    closeButton.controlSize = .small
    closeButton.isBordered = true
    closeButton.showsBorderOnlyWhileMouseInside = true
    closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "退出")
    closeButton.imagePosition = .imageOnly
    closeButton.contentTintColor = .secondaryLabelColor
    closeButton.target = self
    closeButton.action = #selector(closePanel)
    closeButton.keyEquivalent = "\u{1b}"
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.widthAnchor.constraint(equalToConstant: OverlayMetrics.controlHitSize).isActive =
      true
    closeButton.heightAnchor.constraint(equalToConstant: OverlayMetrics.controlHitSize).isActive =
      true
    closeButton.setAccessibilityLabel("关闭 Mien 对话")
    closeButton.setAccessibilityHelp("按 Escape 退出，不会修改原应用")

    let dragRegion = WindowDragRegionView()
    dragRegion.setContentHuggingPriority(.init(1), for: .horizontal)
    dragRegion.setAccessibilityElement(false)
    dragRegion.toolTip = "拖动 Mien"
    contextLabel.font = OverlayTypography.context
    contextLabel.textColor = .secondaryLabelColor
    contextLabel.lineBreakMode = .byTruncatingMiddle
    contextLabel.maximumNumberOfLines = 1
    contextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    contextLabel.setAccessibilityLabel("当前目标")
    let targetMark = NSImageView()
    targetMark.image = MienMark.image(size: 16)
    targetMark.imageScaling = .scaleNone
    targetMark.contentTintColor = .secondaryLabelColor
    targetMark.setAccessibilityElement(false)
    let chrome = NSStackView(views: [
      targetMark, contextLabel, dragRegion, escapeLabel, closeButton,
    ])
    chrome.orientation = .horizontal
    chrome.alignment = .centerY
    chrome.distribution = .fill
    chrome.spacing = 6
    chrome.translatesAutoresizingMaskIntoConstraints = false

    intentTextView.font = OverlayTypography.input
    intentTextView.textColor = .textColor
    intentTextView.drawsBackground = false
    intentTextView.isRichText = false
    intentTextView.importsGraphics = false
    intentTextView.allowsUndo = true
    intentTextView.isHorizontallyResizable = false
    intentTextView.isVerticallyResizable = true
    intentTextView.textContainerInset = NSSize(width: 0, height: 6)
    intentTextView.textContainer?.lineFragmentPadding = 0
    intentTextView.textContainer?.widthTracksTextView = true
    intentTextView.textContainer?.containerSize = NSSize(
      width: 0,
      height: CGFloat.greatestFiniteMagnitude
    )
    intentTextView.frame = NSRect(
      x: 0,
      y: 0,
      width:
        OverlayMetrics.panelWidth - OverlayMetrics.padding * 2
        - OverlayMetrics.contentInset * 2 - 36,
      height: OverlayMetrics.controlHeight
    )
    intentTextView.autoresizingMask = [.width]
    intentTextView.delegate = self
    intentTextView.onInputStateChange = { [weak self] in
      self?.updateInputState()
    }
    intentTextView.setAccessibilityLabel("询问 Mien")
    intentTextView.setAccessibilityHelp("Return 发送；Shift-Return 或 Option-Return 换行")

    inputScrollView.documentView = intentTextView
    inputScrollView.drawsBackground = false
    inputScrollView.borderType = .noBorder
    inputScrollView.hasHorizontalScroller = false
    inputScrollView.hasVerticalScroller = false
    inputScrollView.autohidesScrollers = true
    inputScrollView.scrollerStyle = .overlay
    inputScrollView.translatesAutoresizingMaskIntoConstraints = false

    placeholderLabel.font = OverlayTypography.input
    placeholderLabel.textColor = .placeholderTextColor
    placeholderLabel.setAccessibilityElement(false)
    placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

    let inputContainer = NSView()
    inputContainer.translatesAutoresizingMaskIntoConstraints = false
    inputContainer.addSubview(inputScrollView)
    inputContainer.addSubview(placeholderLabel)
    previewCaret.wantsLayer = true
    previewCaret.layer?.backgroundColor = NSColor.textColor.cgColor
    previewCaret.isHidden = true
    previewCaret.translatesAutoresizingMaskIntoConstraints = false
    inputContainer.addSubview(previewCaret)
    NSLayoutConstraint.activate([
      inputScrollView.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor),
      inputScrollView.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor),
      inputScrollView.topAnchor.constraint(equalTo: inputContainer.topAnchor),
      inputScrollView.bottomAnchor.constraint(equalTo: inputContainer.bottomAnchor),
      placeholderLabel.leadingAnchor.constraint(
        equalTo: inputContainer.leadingAnchor
      ),
      placeholderLabel.topAnchor.constraint(equalTo: inputContainer.topAnchor, constant: 6),
      previewCaret.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor),
      previewCaret.topAnchor.constraint(equalTo: inputContainer.topAnchor, constant: 6),
      previewCaret.widthAnchor.constraint(equalToConstant: 1),
      previewCaret.heightAnchor.constraint(equalToConstant: 20),
    ])

    submitButton.bezelStyle = .push
    submitButton.bezelColor = MienAppearance.accent
    submitButton.controlSize = .regular
    submitButton.isBordered = false
    submitButton.title = ""
    submitButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "发送")
    submitButton.imagePosition = .imageOnly
    submitButton.target = self
    submitButton.action = #selector(submitIntent)
    submitButton.isEnabled = false
    submitButton.contentTintColor = MienAppearance.accentInk
    submitButton.translatesAutoresizingMaskIntoConstraints = false
    submitButton.widthAnchor.constraint(equalToConstant: 30).isActive =
      true
    submitButton.heightAnchor.constraint(equalToConstant: 30).isActive =
      true

    composerRow.orientation = .horizontal
    composerRow.alignment = .centerY
    composerRow.distribution = .fill
    composerRow.spacing = 8
    composerRow.addArrangedSubview(inputContainer)
    composerRow.addArrangedSubview(submitButton)
    composerRow.translatesAutoresizingMaskIntoConstraints = false
    let composerHeight = composerRow.heightAnchor.constraint(
      equalToConstant: OverlayMetrics.controlHeight
    )
    composerHeightConstraint = composerHeight
    composerHeight.isActive = true

    bodyStack.orientation = .vertical
    bodyStack.alignment = .centerX
    bodyStack.spacing = OverlayMetrics.composerGap
    bodyStack.translatesAutoresizingMaskIntoConstraints = false
    bodyStack.addArrangedSubview(transcript)
    composerSurface = MienAppearance.inputSurface(containing: composerRow)
    bodyStack.addArrangedSubview(composerSurface)
    transcript.isHidden = true
    transcript.translatesAutoresizingMaskIntoConstraints = false
    transcript.onContentSizeChange = { [weak self] in self?.onContentSizeChange?() }
    transcript.onAction = { [weak self] turn, action in
      guard let self, turn === self.lastTurn else { return }
      self.onResultAction?(action)
    }
    transcript.onRetry = { [weak self] turn in self?.retry(turn) }
    let scrollHeight = transcript.heightAnchor.constraint(equalToConstant: 0)
    scrollHeightConstraint = scrollHeight
    surface.addSubview(bodyStack)
    surface.addSubview(chrome)
    NSLayoutConstraint.activate([
      bodyStack.leadingAnchor.constraint(
        equalTo: surface.leadingAnchor, constant: OverlayMetrics.padding),
      bodyStack.trailingAnchor.constraint(
        equalTo: surface.trailingAnchor, constant: -OverlayMetrics.padding),
      bodyStack.topAnchor.constraint(equalTo: surface.topAnchor, constant: OverlayMetrics.topInset),
      // Viewport height is explicit below. Do not also constrain the bottom to
      // the previous window size while a content-driven resize is pending.
      transcript.widthAnchor.constraint(equalTo: bodyStack.widthAnchor),
      composerSurface.widthAnchor.constraint(equalTo: bodyStack.widthAnchor),
      chrome.leadingAnchor.constraint(
        equalTo: surface.leadingAnchor, constant: OverlayMetrics.padding),
      chrome.trailingAnchor.constraint(
        equalTo: surface.trailingAnchor, constant: -OverlayMetrics.padding),
      chrome.topAnchor.constraint(equalTo: surface.topAnchor, constant: 8),
      chrome.heightAnchor.constraint(equalToConstant: OverlayMetrics.controlHitSize),
      scrollHeight,
    ])
    view = surface
  }

  func configure(context: String, intent: String = "") {
    transcript.reset()
    transcript.isHidden = true
    activeTurn = nil
    lastTurn = nil
    turnsByTaskID.removeAll()
    boundTaskID = nil
    acceptsSubmission = true
    composerSurface.isHidden = false
    intentTextView.isEditable = true
    intentTextView.unmarkText()
    intentTextView.string = intent
    placeholderLabel.stringValue = "对当前窗口提问…"
    updateInputState(notify: false)
    contextLabel.stringValue = context
    contextLabel.toolTip = context
    accessibilityContext = context
    accessibilityDisclosure = nil
    updateAccessibilityContext()
    updateComposerHeight(notify: false)
    updateDocumentLayout(scrollToBottom: true)
  }

  func setComposerTextForPreview(_ text: String) {
    guard acceptsSubmission else { return }
    intentTextView.string = text
    updateInputState(notify: false)
  }

  func setMarkedTextForTesting(_ text: String) {
    intentTextView.setMarkedText(
      text,
      selectedRange: NSRange(location: text.utf16.count, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0)
    )
  }

  func settleMotionForRendering() {
    lastTurnView?.settleProcessDisclosure()
    if !composerSurface.isHidden {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        composerRow.animator().alphaValue = 1
      }
      composerRow.alphaValue = 1
    }
  }

  func setResultRevealProgressForPreview(_ progress: CGFloat) {
    lastTurnView?.setResultRevealProgressForPreview(progress)
  }

  func showCaretForPreview() {
    previewCaret.isHidden = false
  }

  func submitCurrentTextForTesting() {
    submitIntent()
  }

  func toggleLastProcessForTesting() {
    lastTurnView?.toggleProcessForTesting()
  }

  func retryLastForTesting() {
    lastTurn.map { retry($0) }
  }

  func bind(taskID: UUID) {
    boundTaskID = taskID
    if let activeTurn {
      turnsByTaskID[taskID] = activeTurn
    }
  }

  func presentActivity(_ presentation: AgentActivityPresentation) {
    guard let activeTurn else { return }
    activeTurn.record(presentation)
    transcript.update(activeTurn) { $0.presentActivity(presentation) }
  }

  func setContextDisclosure(_ disclosure: String) {
    accessibilityDisclosure = disclosure
    updateAccessibilityContext()
  }

  private func updateAccessibilityContext() {
    let parts = [accessibilityContext, accessibilityDisclosure]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
    view.setAccessibilityHelp(parts.joined(separator: " · "))
  }

  func focusInput() {
    guard !composerSurface.isHidden, acceptsSubmission,
      let window = view.window, window.isVisible
    else { return }
    window.makeFirstResponder(intentTextView)
    intentTextView.setSelectedRange(NSRange(location: intentTextView.string.utf16.count, length: 0))
  }

  func setStatus(_ text: String, allowsRetry: Bool = false) {
    guard let activeTurn else {
      if let lastTurn {
        lastTurn.postResultStatus = text
        transcript.update(lastTurn) { $0.presentPostResultStatus(text) }
      }
      return
    }
    guard allowsRetry else { return }
    self.activeTurn = nil
    lastTurn = activeTurn
    activeTurn.outcome = .init(
      result: "", status: text, tone: .failure, action: nil, retryable: true)
    transcript.update(activeTurn) { $0.completeWithFailure(text, retryable: true) }
    revealComposer(focus: !NSWorkspace.shared.isVoiceOverEnabled)
  }

  func beginRunning(submittedText: String? = nil) {
    guard acceptsSubmission else { return }
    let rawText = submittedText ?? intentTextView.string
    guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    view.window?.makeFirstResponder(nil)
    let turn = ConversationTurn(userText: rawText)
    // Historical actions cannot operate on the current task binding.
    if let lastTurn {
      lastTurn.actionEnabled = false
      transcript.update(lastTurn) { $0.setActionEnabled(false) }
    }
    activeTurn = turn
    lastTurn = turn
    boundTaskID = nil
    acceptsSubmission = false
    intentTextView.isEditable = false
    composerSurface.isHidden = true
    transcript.isHidden = false
    setSubmitEnabled(false)
    transcript.append(turn)
    contentDidChange(forceScrollToBottom: true)
    NSAccessibility.post(element: view, notification: .layoutChanged)
  }

  func showResult(
    _ text: String,
    status: String,
    action: TaskPresentationAction? = nil,
    tone: TaskPresentationOutcome = .success
  ) {
    let turn = boundTaskID.flatMap { turnsByTaskID[$0] } ?? activeTurn ?? lastTurn
    guard let turn else { return }
    lastTurn = turn
    if activeTurn === turn { activeTurn = nil }
    let effectiveTone: TaskPresentationOutcome =
      action != nil && tone == .success ? .actionRequired : tone
    turn.outcome = .init(
      result: text, status: status, tone: effectiveTone, action: action, retryable: false)
    turn.processExpanded = false
    turn.actionEnabled = true
    turn.postResultStatus = nil
    transcript.update(turn) { row in
      row.complete(result: text, status: status, tone: effectiveTone, action: action)
    }
    if action == nil {
      revealComposer(focus: !NSWorkspace.shared.isVoiceOverEnabled)
    } else {
      transcript.view(for: turn)?.focusAction()
    }
    contentDidChange()
  }

  func showActionPrompt(status: String, action: TaskPresentationAction) {
    showResult("", status: status, action: action, tone: .actionRequired)
  }

  /// Continue the original immutable turn through the ordinary submission
  /// callback, which renews target authority and binds a fresh Host task.
  @discardableResult
  func resumeAfterAuthentication() -> Bool {
    guard activeTurn == nil, let lastTurn, lastTurn.outcome?.action == .loginCodex else {
      return false
    }
    retry(lastTurn)
    return true
  }

  func setResultActionEnabled(_ enabled: Bool) {
    guard let turn = boundTaskID.flatMap({ turnsByTaskID[$0] }) ?? lastTurn else { return }
    turn.actionEnabled = enabled
    transcript.update(turn) { $0.setActionEnabled(enabled) }
  }

  func invalidateConversation(status: String) {
    acceptsSubmission = false
    intentTextView.isEditable = false
    composerSurface.isHidden = true
    boundTaskID = nil
    let turn = activeTurn ?? lastTurn
    activeTurn = nil
    lastTurn = turn
    guard let turn else { return }
    turn.outcome = .init(result: "", status: status, tone: .failure, action: nil, retryable: false)
    transcript.update(turn) { $0.completeWithFailure(status, retryable: false) }
    contentDidChange()
  }

  func preferredPanelHeight(limit: Double) -> Double {
    let fixed = OverlayMetrics.chromeHeight(includesAction: false)
    let composer =
      composerSurface.isHidden
      ? 0
      : (composerHeightConstraint.map { Double($0.constant) } ?? OverlayMetrics.controlHeight)
        + OverlayMetrics.inputPadding
    let gap: Double =
      !transcript.isHidden && !composerSurface.isHidden ? OverlayMetrics.composerGap : 0
    let historyLimit = max(0, limit - fixed - composer - gap)
    scrollHeightConstraint?.constant = min(transcript.contentHeight, historyLimit)
    view.layoutSubtreeIfNeeded()
    transcript.layoutVisibleRows(followLatest: transcript.followsLatest)
    return min(limit, fixed + composer + gap + (scrollHeightConstraint?.constant ?? 0)).rounded(.up)
  }

  func resultHeight(fitting width: Double, limit: Double) -> Double {
    let line = OverlayMetrics.resultLineHeight
    return (min(contentHeight(), limit) / line).rounded(.up) * line
  }

  func applyResultHeight(_ height: Double) {
    scrollHeightConstraint?.constant = max(OverlayMetrics.controlHeight, height)
  }

  var laidOutResultHeight: Double {
    view.layoutSubtreeIfNeeded()
    return transcript.frame.height
  }

  func textDidChange(_ notification: Notification) {
    updateInputState()
  }

  private func updateInputState(notify: Bool = true) {
    let rawText = intentTextView.string
    let hasMarkedText = intentTextView.hasMarkedText()
    placeholderLabel.isHidden = hasMarkedText || !rawText.isEmpty
    setSubmitEnabled(
      acceptsSubmission
        && !hasMarkedText
        && !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    )
    updateComposerHeight(notify: notify)
  }

  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      onCancel?()
      return true
    }
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      guard !textView.hasMarkedText() else { return true }
      let modifiers =
        NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask)
        ?? []
      if modifiers.contains(.shift) || modifiers.contains(.option) { return false }
      submitIntent()
      return true
    }
    return false
  }

  @objc private func submitIntent() {
    let rawText = intentTextView.string
    guard acceptsSubmission,
      !intentTextView.hasMarkedText(),
      !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    beginRunning(submittedText: rawText)
    onSubmit?(rawText)
  }

  @objc private func closePanel() {
    onCancel?()
  }

  override func cancelOperation(_ sender: Any?) {
    onCancel?()
  }

  private func revealComposer(focus: Bool = true) {
    acceptsSubmission = true
    intentTextView.isEditable = true
    intentTextView.unmarkText()
    intentTextView.string = ""
    placeholderLabel.stringValue = "继续提问…"
    placeholderLabel.isHidden = false
    composerHeightConstraint?.constant = OverlayMetrics.controlHeight
    composerRow.alphaValue = 0
    composerSurface.isHidden = false
    setSubmitEnabled(false)
    contentDidChange()
    if focus { focusInput() }
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.24
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        composerRow.animator().alphaValue = 1
      },
      completionHandler: { [weak self] in
        MainActor.assumeIsolated {
          if let composerRow = self?.composerRow {
            NSAccessibility.post(element: composerRow, notification: .layoutChanged)
          }
        }
      })
  }

  private func setSubmitEnabled(_ enabled: Bool) {
    submitButton.isEnabled = enabled
  }

  private func contentDidChange(forceScrollToBottom: Bool = false) {
    updateDocumentLayout(scrollToBottom: forceScrollToBottom || transcript.followsLatest)
    onContentSizeChange?()
  }

  private func contentHeight() -> Double {
    transcript.contentHeight
      + (composerSurface.isHidden
        ? 0
        : (composerHeightConstraint.map { Double($0.constant) } ?? OverlayMetrics.controlHeight)
          + OverlayMetrics.inputPadding)
  }

  private func updateDocumentLayout(scrollToBottom: Bool) {
    let composer =
      composerSurface.isHidden
      ? 0
      : (composerHeightConstraint.map { Double($0.constant) } ?? OverlayMetrics.controlHeight)
        + OverlayMetrics.inputPadding
    scrollHeightConstraint?.constant = min(
      transcript.contentHeight,
      max(
        100,
        view.frame.height - OverlayMetrics.chromeHeight(includesAction: false) - composer
          - OverlayMetrics.composerGap)
    )
    view.layoutSubtreeIfNeeded()
    transcript.layoutVisibleRows(followLatest: scrollToBottom)
  }

  private func updateComposerHeight(notify: Bool = true) {
    let width = max(
      1,
      inputScrollView.contentSize.width > 1
        ? inputScrollView.contentSize.width
        : OverlayMetrics.panelWidth - OverlayMetrics.padding * 2
          - OverlayMetrics.contentInset * 2 - 36
    )
    intentTextView.frame.size.width = width
    guard let layoutManager = intentTextView.layoutManager,
      let textContainer = intentTextView.textContainer
    else { return }
    layoutManager.ensureLayout(for: textContainer)
    let usedHeight =
      layoutManager.usedRect(for: textContainer).height
      + intentTextView.textContainerInset.height * 2
    let height = min(
      OverlayMetrics.maximumComposerHeight,
      max(OverlayMetrics.controlHeight, ceil(usedHeight))
    )
    let changed = abs((composerHeightConstraint?.constant ?? 0) - height) > 0.5
    composerHeightConstraint?.constant = height
    inputScrollView.hasVerticalScroller = usedHeight > OverlayMetrics.maximumComposerHeight
    if changed, notify { contentDidChange(forceScrollToBottom: true) }
  }

  private func retry(_ turn: ConversationTurn) {
    guard turn === lastTurn, activeTurn == nil else { return }
    view.window?.makeFirstResponder(nil)
    acceptsSubmission = false
    composerSurface.isHidden = true
    intentTextView.isEditable = false
    boundTaskID = nil
    turn.resetForRetry()
    transcript.update(turn) { $0.prepareForRetry() }
    activeTurn = turn
    contentDidChange(forceScrollToBottom: true)
    onSubmit?(turn.userText)
  }
}
