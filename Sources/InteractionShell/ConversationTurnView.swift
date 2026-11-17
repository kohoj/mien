import AppKit
import Foundation
import QuartzCore

@MainActor
private final class ProgressiveResultRow: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
  }

  required init?(coder: NSCoder) { nil }

  func setRevealProgressForRendering(_ progress: CGFloat) {
    alphaValue = min(1, max(0.35, progress))
  }

  func settleReveal() {
    layer?.removeAllAnimations()
    alphaValue = 1
  }
}

@MainActor
private final class ActivityRowView: NSView {
  private let progressIndicator = NSProgressIndicator()
  private let imageView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private var presentation: AgentActivityPresentation

  init(_ presentation: AgentActivityPresentation) {
    self.presentation = presentation
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    imageView.imageScaling = .scaleProportionallyDown
    imageView.contentTintColor = .secondaryLabelColor
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.setAccessibilityElement(false)
    imageView.isHidden = true

    progressIndicator.style = .spinning
    progressIndicator.controlSize = .small
    progressIndicator.isIndeterminate = true
    progressIndicator.isDisplayedWhenStopped = true
    progressIndicator.translatesAutoresizingMaskIntoConstraints = false
    progressIndicator.setAccessibilityElement(false)

    titleLabel.font = OverlayTypography.activity
    titleLabel.textColor = .secondaryLabelColor
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.setAccessibilityElement(false)

    let stack = NSStackView(views: [progressIndicator, imageView, titleLabel])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.distribution = .fill
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      imageView.widthAnchor.constraint(equalToConstant: 14),
      imageView.heightAnchor.constraint(equalToConstant: 14),
      progressIndicator.widthAnchor.constraint(equalToConstant: 14),
      progressIndicator.heightAnchor.constraint(equalToConstant: 14),
      heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
    ])
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    apply(presentation)
  }

  required init?(coder: NSCoder) { nil }

  func apply(_ presentation: AgentActivityPresentation) {
    let previousStatus = self.presentation.status
    self.presentation = presentation
    titleLabel.stringValue = presentation.title
    titleLabel.font = OverlayTypography.activity
    switch presentation.status {
    case .active:
      imageView.isHidden = true
      progressIndicator.isHidden = false
      progressIndicator.startAnimation(nil)
    case .completed:
      progressIndicator.stopAnimation(nil)
      progressIndicator.isHidden = true
      imageView.isHidden = false
      imageView.image = NSImage(
        systemSymbolName: "checkmark",
        accessibilityDescription: presentation.title
      )
      imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
      imageView.contentTintColor = .tertiaryLabelColor
    case .failed:
      progressIndicator.stopAnimation(nil)
      progressIndicator.isHidden = true
      imageView.isHidden = false
      imageView.image = NSImage(
        systemSymbolName: "exclamationmark.circle",
        accessibilityDescription: presentation.title
      )
      imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
      imageView.contentTintColor = .secondaryLabelColor
    }
    setAccessibilityLabel(presentation.title)
    setAccessibilityValue(accessibilityStatus)
    if previousStatus != presentation.status {
      NSAccessibility.post(element: self, notification: .valueChanged)
    }
  }

  func setOpticalAlpha(_ alpha: CGFloat) {
    alphaValue = alpha
  }

  private var accessibilityStatus: String {
    switch presentation.status {
    case .active: "进行中"
    case .completed: "已完成"
    case .failed: "失败"
    }
  }
}

@MainActor
final class ConversationTurnView: NSView {
  private enum Phase {
    case submitted
    case working
    case answered
    case failed
  }

  private static let maximumVisibleActivities = 4
  private static let maximumRecordedActivities = 24

  var onProcessExpansion: ((Bool) -> Void)?
  var onAction: ((TaskPresentationAction) -> Void)?
  var onRetry: (() -> Void)?
  var onHeightChange: (() -> Void)?

  let userText: String
  private let activityStack = NSStackView()
  private let userLabel: NSTextField
  private let processContainer = NSView()
  private let processButton = NSButton()
  private let copyButton = NSButton()
  private let resultRenderer = ResultWebRendererView()
  private let resultRow = ProgressiveResultRow()
  private let statusIcon = NSImageView()
  private let statusLabel = NSTextField(wrappingLabelWithString: "")
  private let statusRow = NSStackView()
  private let retryButton = NSButton()
  private let actionButton = MienAccentButton()
  private var resultText = ""
  private let actionRow = NSStackView()
  private let contentStack = NSStackView()
  private var activities: [String: ActivityRowView] = [:]
  private var activityOrder: [String] = []
  private var action: TaskPresentationAction?
  private var phase: Phase = .submitted
  private var processIsExpanded = false
  private var activityLeadingConstraint: NSLayoutConstraint!
  private var processHeightConstraint: NSLayoutConstraint!
  private var processTransitionGeneration: UInt64 = 0
  private var showsResult = false
  private var showsStatus = false
  private var showsAction = false

  init(userText: String) {
    self.userText = userText
    userLabel = NSTextField(wrappingLabelWithString: userText)
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    userLabel.font = OverlayTypography.user
    userLabel.textColor = .secondaryLabelColor
    userLabel.maximumNumberOfLines = 0
    userLabel.isSelectable = true
    userLabel.isEditable = false
    userLabel.setAccessibilityLabel("已发送的消息")
    userLabel.setAccessibilityValue(userText)

    activityStack.orientation = .vertical
    activityStack.alignment = .leading
    activityStack.spacing = 6
    activityStack.translatesAutoresizingMaskIntoConstraints = false

    processButton.bezelStyle = .accessoryBarAction
    processButton.controlSize = .small
    processButton.isBordered = false
    processButton.font = .systemFont(ofSize: 11, weight: .medium)
    processButton.contentTintColor = .secondaryLabelColor
    processButton.title = "过程"
    processButton.imagePosition = .imageTrailing
    processButton.target = self
    processButton.action = #selector(toggleProcess)
    processButton.translatesAutoresizingMaskIntoConstraints = false
    processButton.isHidden = true
    processButton.heightAnchor.constraint(equalToConstant: 24).isActive = true

    copyButton.title = "复制"
    copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
    copyButton.imagePosition = .imageLeading
    copyButton.bezelStyle = .accessoryBarAction
    copyButton.controlSize = .small
    copyButton.isBordered = false
    copyButton.font = .systemFont(ofSize: 11, weight: .medium)
    copyButton.contentTintColor = .secondaryLabelColor
    copyButton.target = self
    copyButton.action = #selector(copyResult)
    copyButton.setAccessibilityLabel("复制回答")
    copyButton.translatesAutoresizingMaskIntoConstraints = false
    copyButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
    copyButton.isHidden = true

    processContainer.wantsLayer = true
    processContainer.layer?.masksToBounds = true
    processContainer.isHidden = true
    processContainer.translatesAutoresizingMaskIntoConstraints = false
    processContainer.addSubview(activityStack)
    activityLeadingConstraint = activityStack.leadingAnchor.constraint(
      equalTo: processContainer.leadingAnchor
    )
    processHeightConstraint = processContainer.heightAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      activityLeadingConstraint,
      activityStack.trailingAnchor.constraint(equalTo: processContainer.trailingAnchor),
      activityStack.topAnchor.constraint(equalTo: processContainer.topAnchor),
      processHeightConstraint,
    ])
    updateProcessControl()

    statusIcon.imageScaling = .scaleProportionallyDown
    statusIcon.translatesAutoresizingMaskIntoConstraints = false
    statusIcon.setAccessibilityElement(false)
    statusLabel.font = OverlayTypography.status
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.maximumNumberOfLines = 0
    statusLabel.setAccessibilityLabel("任务状态")

    retryButton.title = "重试"
    retryButton.bezelStyle = .push
    retryButton.controlSize = .small
    retryButton.target = self
    retryButton.action = #selector(retry)
    retryButton.toolTip = "重新读取同一目标并执行这条请求"
    retryButton.setAccessibilityHelp("保留已发送内容，创建新的任务重新尝试")
    retryButton.isHidden = true

    statusRow.orientation = .horizontal
    statusRow.alignment = .centerY
    statusRow.distribution = .fill
    statusRow.spacing = 7
    statusRow.addArrangedSubview(statusIcon)
    statusRow.addArrangedSubview(statusLabel)
    statusRow.addArrangedSubview(NSView())
    statusRow.addArrangedSubview(retryButton)
    statusRow.isHidden = true
    statusRow.translatesAutoresizingMaskIntoConstraints = false

    resultRenderer.onHeightChange = { [weak self] in
      self?.onHeightChange?()
    }
    resultRow.translatesAutoresizingMaskIntoConstraints = false
    resultRow.addSubview(resultRenderer)
    resultRow.isHidden = true

    actionButton.bezelStyle = .push
    actionButton.controlSize = .regular
    actionButton.target = self
    actionButton.action = #selector(performAction)
    actionButton.keyEquivalent = "\r"
    actionButton.keyEquivalentModifierMask = [.command]
    actionButton.translatesAutoresizingMaskIntoConstraints = false
    actionButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
    actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 116).isActive = true
    actionButton.bezelColor = MienAppearance.accent
    actionButton.contentTintColor = MienAppearance.accentInk
    actionRow.addArrangedSubview(processButton)
    actionRow.addArrangedSubview(NSView())
    actionRow.addArrangedSubview(copyButton)
    actionRow.addArrangedSubview(actionButton)
    actionRow.spacing = 10
    actionRow.orientation = .horizontal
    actionRow.distribution = .fill
    actionRow.translatesAutoresizingMaskIntoConstraints = false
    actionRow.isHidden = true

    for view in [
      userLabel,
      processContainer,
      statusRow,
      resultRow,
      actionRow,
    ] {
      contentStack.addArrangedSubview(view)
    }
    contentStack.orientation = .vertical
    contentStack.alignment = .centerX
    contentStack.spacing = 0
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(contentStack)
    NSLayoutConstraint.activate([
      contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
      contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
      contentStack.topAnchor.constraint(equalTo: topAnchor),
      contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
      userLabel.widthAnchor.constraint(
        equalTo: contentStack.widthAnchor,
        constant: -OverlayMetrics.contentInset * 2
      ),
      processContainer.widthAnchor.constraint(
        equalTo: contentStack.widthAnchor,
        constant: -OverlayMetrics.contentInset * 2
      ),
      statusRow.widthAnchor.constraint(
        equalTo: contentStack.widthAnchor,
        constant: -OverlayMetrics.contentInset * 2
      ),
      statusIcon.widthAnchor.constraint(equalToConstant: 14),
      statusIcon.heightAnchor.constraint(equalToConstant: 14),
      resultRow.widthAnchor.constraint(
        equalTo: contentStack.widthAnchor,
        constant: -OverlayMetrics.contentInset * 2
      ),
      resultRenderer.leadingAnchor.constraint(equalTo: resultRow.leadingAnchor),
      resultRenderer.trailingAnchor.constraint(equalTo: resultRow.trailingAnchor),
      resultRenderer.topAnchor.constraint(equalTo: resultRow.topAnchor),
      resultRenderer.bottomAnchor.constraint(equalTo: resultRow.bottomAnchor),
      actionRow.widthAnchor.constraint(
        equalTo: contentStack.widthAnchor,
        constant: -OverlayMetrics.contentInset * 2
      ),
    ])
    updateContentSpacing()
    presentSubmissionActivity()
  }

  required init?(coder: NSCoder) { nil }

  func restore(_ turn: ConversationTurn) {
    if let height = turn.resultHeight { resultRenderer.restoreMeasuredHeight(height) }
    for activity in turn.activities.reversed() { presentActivity(activity) }
    if let outcome = turn.outcome {
      complete(
        result: outcome.result, status: outcome.status, tone: outcome.tone,
        action: outcome.action, retryable: outcome.retryable, announces: false)
      if turn.processExpanded { toggleProcess() }
    }
    setActionEnabled(turn.actionEnabled)
    if let status = turn.postResultStatus { presentPostResultStatus(status) }
  }

  var measuredResultHeight: CGFloat { resultRenderer.measuredHeight }
  func releaseResources() { resultRenderer.releaseResources() }

  var submittedTextIsImmutable: Bool {
    !userLabel.isEditable && userLabel.currentEditor() == nil
  }

  var collapsedProcessUsesText: Bool {
    !processButton.title.isEmpty
  }

  var hasCollapsedProcessSymbol: Bool {
    !processButton.isHidden && processButton.isEnabled && !processIsExpanded
  }

  var visibleTerminalStatus: String? {
    statusRow.isHidden ? nil : statusLabel.stringValue
  }

  var visibleActivityCount: Int {
    activityStack.arrangedSubviews.filter { !$0.isHidden }.count
  }

  var visibleActivityTitles: [String] {
    activityOrder.compactMap { id in
      guard let row = activities[id], !row.isHidden else { return nil }
      return row.accessibilityLabel()
    }
  }

  var processAccessibilityLabel: String? {
    processButton.accessibilityLabel()
  }

  var retryControlIsVisible: Bool {
    !retryButton.isHidden
  }

  var awaitsAuthentication: Bool { action == .loginCodex }

  func toggleProcessForTesting() {
    processButton.performClick(nil)
  }

  func setResultRevealProgressForPreview(_ progress: CGFloat) {
    resultRow.setRevealProgressForRendering(progress)
  }

  func retryForTesting() {
    retry()
  }

  func presentActivity(_ presentation: AgentActivityPresentation) {
    guard phase == .submitted || phase == .working else { return }
    if presentation.kind != .host { removeSubmissionActivity() }
    phase = .working
    if let row = activities[presentation.id] {
      let shouldMoveToFront =
        presentation.status == .active && activityOrder.first != presentation.id
      row.apply(presentation)
      if shouldMoveToFront,
        let previousIndex = activityOrder.firstIndex(of: presentation.id)
      {
        activityOrder.remove(at: previousIndex)
        activityOrder.insert(presentation.id, at: 0)
        activityStack.removeArrangedSubview(row)
        activityStack.insertArrangedSubview(row, at: 0)
      }
    } else {
      if activityOrder.count == Self.maximumRecordedActivities,
        let oldestID = activityOrder.last,
        let oldest = activities.removeValue(forKey: oldestID)
      {
        activityOrder.removeLast()
        activityStack.removeArrangedSubview(oldest)
        oldest.removeFromSuperview()
      }
      let row = ActivityRowView(presentation)
      activities[presentation.id] = row
      activityOrder.insert(presentation.id, at: 0)
      activityStack.insertArrangedSubview(row, at: 0)
      row.widthAnchor.constraint(equalTo: activityStack.widthAnchor).isActive = true
    }
    refreshActivityVisibility(showAll: false)
    showWorkingProcess()
    updateContentSpacing()
    onHeightChange?()
  }

  func complete(
    result: String,
    status: String,
    tone: TaskPresentationOutcome,
    action: TaskPresentationAction?,
    retryable: Bool = false,
    announces: Bool = true
  ) {
    self.action = action
    configureOutcome(
      result: result,
      status: status,
      tone: tone,
      action: action,
      retryable: retryable
    )
    // A typed terminal fact releases interaction immediately. Motion only
    // decorates the committed state; no delayed task owns completion or focus.
    phase = tone == .failure ? .failed : .answered
    removeSubmissionActivity()
    showsAction = showsAction || !activityOrder.isEmpty
    finishProcessCollapse()
    revealOutcome(animated: announces)
    if announces { announceCompletion(tone) }
  }

  func completeWithFailure(
    _ title: String,
    retryable: Bool
  ) {
    complete(
      result: "",
      status: title,
      tone: .failure,
      action: nil,
      retryable: retryable
    )
  }

  func prepareForRetry() {
    for row in activityStack.arrangedSubviews {
      activityStack.removeArrangedSubview(row)
      row.removeFromSuperview()
    }
    activities.removeAll(keepingCapacity: true)
    activityOrder.removeAll(keepingCapacity: true)
    processTransitionGeneration &+= 1
    processIsExpanded = false
    processContainer.isHidden = true
    processHeightConstraint.constant = 0
    processButton.isHidden = true
    activityStack.isHidden = false
    activityStack.alphaValue = 1
    resultRow.isHidden = true
    resultRenderer.clear()
    statusRow.isHidden = true
    actionRow.isHidden = true
    retryButton.isHidden = true
    action = nil
    phase = .working
    updateContentSpacing()
    presentSubmissionActivity()
    onHeightChange?()
    NSAccessibility.post(element: self, notification: .layoutChanged)
  }

  func setActionEnabled(_ enabled: Bool) {
    actionButton.isEnabled = enabled
  }

  func presentPostResultStatus(_ title: String) {
    if !actionButton.isHidden {
      actionButton.title = title
      actionButton.toolTip = title
      actionButton.setAccessibilityLabel(title)
      actionButton.isEnabled = false
    } else {
      statusLabel.stringValue = title
      statusLabel.setAccessibilityValue(title)
      statusIcon.image = NSImage(
        systemSymbolName: "info.circle",
        accessibilityDescription: nil
      )
      statusIcon.contentTintColor = .secondaryLabelColor
      retryButton.isHidden = true
      statusRow.alphaValue = 1
      statusRow.isHidden = false
      NSAccessibility.post(element: statusLabel, notification: .valueChanged)
    }
    updateContentSpacing()
    onHeightChange?()
  }

  func settleProcessDisclosure() {
    resultRow.settleReveal()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      for view in [resultRow, statusRow, actionRow] { view.animator().alphaValue = 1 }
    }
    finishProcessCollapse()
  }

  func focusAction() {
    guard !actionButton.isHidden, actionButton.isEnabled else { return }
    window?.makeFirstResponder(actionButton)
    NSAccessibility.post(element: actionButton, notification: .layoutChanged)
  }

  private func configureOutcome(
    result: String,
    status: String,
    tone: TaskPresentationOutcome,
    action: TaskPresentationAction?,
    retryable: Bool
  ) {
    resultRenderer.render(result)
    resultText = result
    copyButton.title = "复制"
    copyButton.isHidden = result.isEmpty
    actionButton.isHidden = action == nil
    statusLabel.stringValue = status
    statusLabel.setAccessibilityValue(status)
    showsResult = !result.isEmpty
    showsStatus =
      tone == .warning || tone == .failure || (tone == .actionRequired && result.isEmpty)
    showsAction = action != nil || !result.isEmpty
    configureAction(action)
    retryButton.isHidden = tone != .failure || !retryable
    retryButton.isEnabled = retryable
    switch tone {
    case .success:
      statusIcon.image = nil
    case .actionRequired:
      statusIcon.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
      statusIcon.contentTintColor = .secondaryLabelColor
    case .warning:
      statusIcon.image = NSImage(
        systemSymbolName: "exclamationmark.triangle",
        accessibilityDescription: nil
      )
      statusIcon.contentTintColor = .systemOrange
    case .failure:
      statusIcon.image = NSImage(
        systemSymbolName: "exclamationmark.circle",
        accessibilityDescription: nil
      )
      statusIcon.contentTintColor = retryable ? .systemOrange : .systemRed
    }
    for view in [resultRow, statusRow, actionRow] {
      view.alphaValue = 0
      view.isHidden = true
    }
    updateContentSpacing()
  }

  private func revealOutcome(animated: Bool) {
    let views: [NSView] =
      ([
        showsStatus ? statusRow : nil,
        showsResult ? resultRow : nil,
        showsAction ? actionRow : nil,
      ] as [NSView?]).compactMap { $0 }
    for view in views {
      view.alphaValue = 1
      view.isHidden = false
    }
    if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      for view in views { view.alphaValue = 0 }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.20
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        for view in views { view.animator().alphaValue = 1 }
      }
    }
    updateContentSpacing()
    onHeightChange?()
    let changedElement: Any =
      showsResult ? resultRenderer : (showsStatus ? statusLabel : actionButton)
    NSAccessibility.post(element: changedElement, notification: .layoutChanged)
  }

  private func announceCompletion(_ tone: TaskPresentationOutcome) {
    let announcement: String
    switch tone {
    case .success: announcement = "回答已生成"
    case .actionRequired: announcement = "需要你的确认"
    case .warning, .failure: announcement = statusLabel.stringValue
    }
    NSAccessibility.post(
      element: showsResult ? resultRenderer : statusLabel,
      notification: .announcementRequested,
      userInfo: [
        .announcement: announcement,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ]
    )
  }

  private func configureAction(_ action: TaskPresentationAction?) {
    guard let action else { return }
    switch action {
    case .insertDraft:
      actionButton.title = "插入原输入框"
      actionButton.toolTip = "仅写入草稿，不会发送（⌘Return）"
    case .undoDraft:
      actionButton.title = "撤销插入"
      actionButton.toolTip = "输入框未继续修改时恢复原内容（⌘Return）"
    case .loginCodex:
      actionButton.title = "连接 ChatGPT"
      actionButton.toolTip = "在浏览器中连接你的 ChatGPT 账户（⌘Return）"
    }
    actionButton.setAccessibilityLabel(actionButton.title)
    actionButton.isEnabled = true
  }

  private func refreshActivityVisibility(showAll: Bool) {
    let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    for (index, id) in activityOrder.enumerated() {
      guard let row = activities[id] else { continue }
      let visible = showAll || index < Self.maximumVisibleActivities
      row.isHidden = !visible
      guard visible else { continue }
      if showAll || increaseContrast {
        row.setOpticalAlpha(1)
      } else {
        switch index {
        case 0: row.setOpticalAlpha(0.96)
        case 1: row.setOpticalAlpha(0.58)
        case 2: row.setOpticalAlpha(0.44)
        default: row.setOpticalAlpha(0.34)
        }
      }
    }
  }

  private func finishProcessCollapse() {
    processTransitionGeneration &+= 1
    processIsExpanded = false
    processContainer.isHidden = true
    processHeightConstraint.constant = 0
    activityLeadingConstraint.constant = 0
    activityStack.isHidden = true
    activityStack.alphaValue = 1
    processButton.alphaValue = 1
    processButton.isHidden = activityOrder.isEmpty
    updateProcessControl()
    updateContentSpacing()
    onHeightChange?()
  }

  private func updateProcessControl() {
    let label = processIsExpanded ? "收起过程" : "查看过程"
    processButton.image = NSImage(
      systemSymbolName: processIsExpanded ? "chevron.down" : "chevron.right",
      accessibilityDescription: nil)
    processButton.isEnabled = !activityOrder.isEmpty
    processButton.setAccessibilityLabel(label)
    processButton.toolTip = label
    processButton.setAccessibilityHelp(label)
  }

  @objc private func toggleProcess() {
    guard !activityOrder.isEmpty else { return }
    processTransitionGeneration &+= 1
    let generation = processTransitionGeneration
    let expands = !processIsExpanded
    processIsExpanded = expands
    onProcessExpansion?(expands)
    updateProcessControl()
    if expands {
      processContainer.isHidden = false
      activityLeadingConstraint.constant = 0
      refreshActivityVisibility(showAll: true)
      activityStack.alphaValue = 0
      activityStack.isHidden = false
    }
    processButton.alphaValue = 1
    processButton.isHidden = false

    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let targetHeight = expands ? expandedProcessHeight : 0
    guard !reduceMotion else {
      processHeightConstraint.constant = targetHeight
      activityStack.isHidden = !expands
      processContainer.isHidden = !expands
      activityStack.alphaValue = 1
      processButton.isHidden = false
      processButton.alphaValue = 1
      refreshActivityVisibility(showAll: expands)
      if !expands { activityLeadingConstraint.constant = 0 }
      updateContentSpacing()
      onHeightChange?()
      NSAccessibility.post(element: processButton, notification: .valueChanged)
      return
    }

    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.20
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        processHeightConstraint.animator().constant = targetHeight
        activityStack.animator().alphaValue = expands ? 1 : 0
      },
      completionHandler: { [weak self] in
        MainActor.assumeIsolated {
          guard let self, self.processTransitionGeneration == generation else { return }
          self.processHeightConstraint.constant = targetHeight
          self.activityStack.isHidden = !expands
          self.processContainer.isHidden = !expands
          self.activityStack.alphaValue = 1
          self.processButton.isHidden = false
          self.processButton.alphaValue = 1
          self.refreshActivityVisibility(showAll: expands)
          if !expands { self.activityLeadingConstraint.constant = 0 }
          self.updateContentSpacing()
          self.onHeightChange?()
        }
      }
    )
    updateContentSpacing()
    onHeightChange?()
    NSAccessibility.post(element: processButton, notification: .valueChanged)
  }

  @objc private func retry() {
    retryButton.isEnabled = false
    onRetry?()
  }

  @objc private func copyResult() {
    guard !resultText.isEmpty else { return }
    NSPasteboard.general.clearContents()
    guard NSPasteboard.general.setString(resultText, forType: .string) else { return }
    copyButton.title = "已复制"
    NSAccessibility.post(
      element: copyButton, notification: .announcementRequested,
      userInfo: [
        .announcement: "回答已复制",
        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
      ])
  }

  private func removeSubmissionActivity() {
    guard let pending = activities.removeValue(forKey: "host:submission") else { return }
    activityOrder.removeAll { $0 == "host:submission" }
    activityStack.removeArrangedSubview(pending)
    pending.removeFromSuperview()
  }

  private func presentSubmissionActivity() {
    presentActivity(
      AgentActivityPresentation(id: "host:submission", kind: .host, toolName: nil, status: .active)
    )
  }

  @objc private func performAction() {
    guard let action else { return }
    actionButton.isEnabled = false
    onAction?(action)
  }

  private var expandedProcessHeight: CGFloat {
    activityStack.layoutSubtreeIfNeeded()
    return max(OverlayMetrics.controlHitSize, ceil(activityStack.fittingSize.height))
  }

  private func showWorkingProcess() {
    processTransitionGeneration &+= 1
    processIsExpanded = false
    processContainer.isHidden = false
    activityLeadingConstraint.constant = 0
    activityStack.isHidden = false
    activityStack.alphaValue = 1
    processButton.isHidden = true
    processButton.alphaValue = 1
    processHeightConstraint.constant = expandedProcessHeight
    updateProcessControl()
  }

  private func updateContentSpacing() {
    for view in [
      userLabel,
      processContainer,
      statusRow,
      resultRow,
      actionRow,
    ] {
      contentStack.setCustomSpacing(0, after: view)
    }

    contentStack.setCustomSpacing(18, after: userLabel)
    if !processContainer.isHidden, showsResult {
      contentStack.setCustomSpacing(activityStack.isHidden ? 8 : 12, after: processContainer)
    }
    if !statusRow.isHidden {
      contentStack.setCustomSpacing(showsResult ? 8 : 12, after: statusRow)
    }
    if !resultRow.isHidden {
      contentStack.setCustomSpacing(8, after: resultRow)
    }
    if !actionRow.isHidden {
      contentStack.setCustomSpacing(16, after: actionRow)
    }
  }
}
