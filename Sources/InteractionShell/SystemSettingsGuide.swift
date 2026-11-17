import AppKit
import CoreGraphics
import InvocationKernel
import MienContracts
import PermissionKernel
import QuartzCore

enum SystemSettingsGuideError: LocalizedError {
  case applicationBundleUnavailable(URL)

  var errorDescription: String? {
    switch self {
    case .applicationBundleUnavailable(let url):
      "权限引导需要从 Mien.app 运行；当前路径是 \(url.path)。"
    }
  }
}

final class AppBundlePasteboardWriter: NSObject, NSPasteboardWriting {
  static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
  static let promisedFileURLType = NSPasteboard.PasteboardType(
    "com.apple.pasteboard.promised-file-url"
  )

  let url: URL

  init(url: URL) {
    self.url = url
  }

  func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
    [.fileURL, .URL, Self.filenamesType, Self.promisedFileURLType, .string]
  }

  func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
    switch type {
    case .fileURL, .URL, Self.promisedFileURLType:
      url.absoluteString
    case Self.filenamesType:
      [url.path]
    case .string:
      url.path
    default:
      nil
    }
  }
}

struct SystemSettingsGuidePlacement {
  static let sidebarWidth: CGFloat = 230
  static let screenInset: CGFloat = 12

  static func frame(
    settingsFrame: CGRect,
    panelHeight: CGFloat,
    visibleFrame: CGRect
  ) -> CGRect {
    let maximumWidth = max(240, visibleFrame.width - screenInset * 2)
    let width = min(max(240, settingsFrame.width - sidebarWidth), maximumWidth)
    let usableFrame = visibleFrame.insetBy(dx: screenInset, dy: screenInset)
    let proposed = CGRect(
      x: settingsFrame.minX + sidebarWidth,
      y: settingsFrame.minY - panelHeight,
      width: width,
      height: panelHeight
    )
    guard usableFrame.width >= width, usableFrame.height >= panelHeight else {
      return CGRect(origin: usableFrame.origin, size: proposed.size)
    }
    return CGRect(
      x: min(max(proposed.minX, usableFrame.minX), usableFrame.maxX - width),
      y: min(max(proposed.minY, usableFrame.minY), usableFrame.maxY - panelHeight),
      width: width,
      height: panelHeight
    )
  }

  static func launchFrame(sourceFrame: CGRect, panelSize: CGSize) -> CGRect {
    guard !sourceFrame.isEmpty else { return CGRect(origin: .zero, size: panelSize) }
    let size = CGSize(
      width: max(sourceFrame.width, panelSize.width * 0.58),
      height: max(sourceFrame.height, panelSize.height * 0.58)
    )
    return CGRect(
      x: sourceFrame.midX - size.width / 2,
      y: sourceFrame.midY - size.height / 2,
      width: size.width,
      height: size.height
    )
  }
}

@MainActor
private final class PermissionGuidePanel: NSPanel {
  var onInteraction: (() -> Void)?

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown || event.type == .rightMouseDown {
      onInteraction?()
    }
    super.sendEvent(event)
  }
}

@MainActor
private final class SystemSettingsGuideContentView: NSVisualEffectView {
  var onClose: (() -> Void)?
  var onReopenSettings: (() -> Void)?
  var onDragStateChange: ((Bool) -> Void)?

  private let titleLabel = NSTextField(wrappingLabelWithString: "")
  private let dragSource: AppBundleDragSourceView
  private let reopenButton = NSButton()

  init(applicationURL: URL) {
    dragSource = AppBundleDragSourceView(applicationURL: applicationURL)
    super.init(frame: .zero)
    build()
    configure(permission: .screenRecording, applicationURL: applicationURL)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  func configure(permission: DesktopPermission, applicationURL: URL) {
    let applicationName = FileManager.default.displayName(atPath: applicationURL.path)
      .replacingOccurrences(of: ".app", with: "")
    let permissionName: String
    switch permission {
    case .accessibility: permissionName = "辅助功能"
    case .screenRecording: permissionName = "屏幕与系统录音"
    }
    titleLabel.stringValue = "为 \(applicationName) 打开\(permissionName)。未找到时，将下方图标拖入列表。"
    titleLabel.setAccessibilityLabel(titleLabel.stringValue)
    dragSource.update(applicationURL: applicationURL)
  }

  func setSettingsFrontmost(_ isFrontmost: Bool) {
    reopenButton.isHidden = isFrontmost
  }

  func setApplicationIcon(_ image: NSImage) {
    dragSource.setApplicationIcon(image)
  }

  private func build() {
    material = .popover
    blendingMode = .behindWindow
    state = .active
    wantsLayer = true
    layer?.cornerRadius = 14
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 0.5
    layer?.borderColor = NSColor.separatorColor.cgColor

    let directionIcon = NSImageView()
    directionIcon.image = NSImage(
      systemSymbolName: "arrow.up",
      accessibilityDescription: "拖到上方"
    )
    directionIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    directionIcon.contentTintColor = MienAppearance.accent
    directionIcon.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.font = .systemFont(ofSize: 13.5, weight: .medium)
    titleLabel.textColor = .labelColor
    titleLabel.maximumNumberOfLines = 2
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    reopenButton.image = NSImage(
      systemSymbolName: "gearshape.fill",
      accessibilityDescription: "重新打开系统设置"
    )
    reopenButton.bezelStyle = .inline
    reopenButton.isBordered = false
    reopenButton.contentTintColor = .secondaryLabelColor
    reopenButton.target = self
    reopenButton.action = #selector(reopenSettings)
    reopenButton.toolTip = "重新打开系统设置"
    reopenButton.setAccessibilityLabel("重新打开系统设置")
    reopenButton.translatesAutoresizingMaskIntoConstraints = false

    let closeButton = NSButton(
      image: NSImage(
        systemSymbolName: "xmark.circle.fill",
        accessibilityDescription: "关闭权限指引"
      ) ?? NSImage(),
      target: self,
      action: #selector(closeGuide)
    )
    closeButton.bezelStyle = .inline
    closeButton.isBordered = false
    closeButton.contentTintColor = .secondaryLabelColor
    closeButton.setAccessibilityLabel("关闭权限指引")
    closeButton.translatesAutoresizingMaskIntoConstraints = false

    dragSource.onDragStateChange = { [weak self] isDragging in
      self?.onDragStateChange?(isDragging)
    }
    dragSource.translatesAutoresizingMaskIntoConstraints = false

    addSubview(directionIcon)
    addSubview(titleLabel)
    addSubview(reopenButton)
    addSubview(closeButton)
    addSubview(dragSource)
    NSLayoutConstraint.activate([
      directionIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      directionIcon.topAnchor.constraint(equalTo: topAnchor, constant: 17),
      directionIcon.widthAnchor.constraint(equalToConstant: 18),
      directionIcon.heightAnchor.constraint(equalToConstant: 18),

      titleLabel.leadingAnchor.constraint(equalTo: directionIcon.trailingAnchor, constant: 8),
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 15),
      titleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: reopenButton.leadingAnchor, constant: -8),

      reopenButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
      reopenButton.topAnchor.constraint(equalTo: topAnchor, constant: 13),
      reopenButton.widthAnchor.constraint(equalToConstant: 24),
      reopenButton.heightAnchor.constraint(equalToConstant: 24),

      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 13),
      closeButton.widthAnchor.constraint(equalToConstant: 24),
      closeButton.heightAnchor.constraint(equalToConstant: 24),

      dragSource.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      dragSource.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      dragSource.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
      dragSource.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
      dragSource.heightAnchor.constraint(equalToConstant: 58),
    ])
    setAccessibilityElement(false)
  }

  @objc private func closeGuide() { onClose?() }
  @objc private func reopenSettings() { onReopenSettings?() }
}

@MainActor
private final class AppBundleDragSourceView: NSView, NSDraggingSource {
  var onDragStateChange: ((Bool) -> Void)?

  private var applicationURL: URL
  private let iconView = NSImageView()
  private let nameLabel = NSTextField(labelWithString: "")
  private let revealLabel = NSTextField(labelWithString: "点按可在 Finder 中显示")
  private var mouseDownPoint: CGPoint?
  private var hasBegunDragging = false

  init(applicationURL: URL) {
    self.applicationURL = applicationURL
    super.init(frame: .zero)
    build()
    update(applicationURL: applicationURL)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  func update(applicationURL: URL) {
    self.applicationURL = applicationURL
    iconView.image = NSWorkspace.shared.icon(forFile: applicationURL.path)
    nameLabel.stringValue = FileManager.default.displayName(atPath: applicationURL.path)
      .replacingOccurrences(of: ".app", with: "")
    setAccessibilityLabel("\(nameLabel.stringValue) 应用")
  }

  func setApplicationIcon(_ image: NSImage) {
    iconView.image = image
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(point) ? self : nil
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  override func mouseDown(with event: NSEvent) {
    mouseDownPoint = convert(event.locationInWindow, from: nil)
    hasBegunDragging = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard !hasBegunDragging, let mouseDownPoint else { return }
    let point = convert(event.locationInWindow, from: nil)
    guard hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 4 else { return }
    hasBegunDragging = true
    beginApplicationDrag(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    if !hasBegunDragging { revealInFinder() }
    mouseDownPoint = nil
    hasBegunDragging = false
  }

  override func accessibilityPerformPress() -> Bool {
    revealInFinder()
    return true
  }

  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    .copy
  }

  func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

  func draggingSession(
    _ session: NSDraggingSession,
    willBeginAt screenPoint: NSPoint
  ) {
    onDragStateChange?(true)
  }

  func draggingSession(
    _ session: NSDraggingSession,
    endedAt screenPoint: NSPoint,
    operation: NSDragOperation
  ) {
    onDragStateChange?(false)
    mouseDownPoint = nil
    hasBegunDragging = false
  }

  private func build() {
    wantsLayer = true
    layer?.cornerRadius = 11
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 0.5
    updateColors()

    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.wantsLayer = true
    iconView.layer?.cornerRadius = 8
    iconView.translatesAutoresizingMaskIntoConstraints = false

    nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
    nameLabel.textColor = .labelColor

    revealLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
    revealLabel.textColor = .secondaryLabelColor

    let copy = NSStackView(views: [nameLabel, revealLabel])
    copy.orientation = .vertical
    copy.alignment = .leading
    copy.spacing = 2
    copy.translatesAutoresizingMaskIntoConstraints = false

    let handIcon = NSImageView()
    handIcon.image = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: nil)
    handIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    handIcon.contentTintColor = .secondaryLabelColor
    handIcon.translatesAutoresizingMaskIntoConstraints = false

    let dragLabel = NSTextField(labelWithString: "拖动")
    dragLabel.font = .systemFont(ofSize: 9, weight: .regular)
    dragLabel.textColor = .secondaryLabelColor
    let affordance = NSStackView(views: [handIcon, dragLabel])
    affordance.orientation = .vertical
    affordance.alignment = .centerX
    affordance.spacing = 1
    affordance.translatesAutoresizingMaskIntoConstraints = false

    addSubview(iconView)
    addSubview(copy)
    addSubview(affordance)
    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 36),
      iconView.heightAnchor.constraint(equalToConstant: 36),
      copy.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
      copy.centerYAnchor.constraint(equalTo: centerYAnchor),
      copy.trailingAnchor.constraint(
        lessThanOrEqualTo: affordance.leadingAnchor, constant: -12),
      affordance.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      affordance.centerYAnchor.constraint(equalTo: centerYAnchor),
      handIcon.widthAnchor.constraint(equalToConstant: 18),
      handIcon.heightAnchor.constraint(equalToConstant: 18),
    ])

    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityHelp("拖到上方权限列表；按下可在 Finder 中显示，然后用加号选择")
  }

  private func beginApplicationDrag(with event: NSEvent) {
    let item = NSDraggingItem(pasteboardWriter: AppBundlePasteboardWriter(url: applicationURL))
    let dragImage = NSWorkspace.shared.icon(forFile: applicationURL.path)
    dragImage.size = NSSize(width: 56, height: 56)
    let point = convert(event.locationInWindow, from: nil)
    item.setDraggingFrame(
      CGRect(x: point.x - 28, y: point.y - 28, width: 56, height: 56),
      contents: dragImage
    )
    let session = beginDraggingSession(with: [item], event: event, source: self)
    session.animatesToStartingPositionsOnCancelOrFail = true
    session.draggingFormation = .none
  }

  private func revealInFinder() {
    NSWorkspace.shared.activateFileViewerSelecting([applicationURL])
  }

  private func updateColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
      layer?.borderColor = NSColor.separatorColor.cgColor
    }
  }
}

@MainActor
final class SystemSettingsGuideController {
  private static let settingsBundleIdentifier = "com.apple.systempreferences"
  private static let panelSize = CGSize(width: 420, height: 132)

  private let panel: PermissionGuidePanel
  private let contentView: SystemSettingsGuideContentView
  private let settingsRouter = DesktopPermissionSettingsRouter()
  private var timer: Timer?
  private var hasFoundSettingsWindow = false
  private var hasPresentedTarget = false
  private var hasActivatedSettings = false
  private var isDragging = false
  private var trackingStartedAt = Date()
  private var launchAnimationDeadline = Date.distantPast
  private var previousApplication: NSRunningApplication?
  private var settingsApplication: NSRunningApplication?

  private(set) var permission: DesktopPermission?

  init() {
    let applicationURL = Bundle.main.bundleURL
    contentView = SystemSettingsGuideContentView(applicationURL: applicationURL)
    panel = PermissionGuidePanel(
      contentRect: CGRect(origin: .zero, size: Self.panelSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.level = .floating
    panel.becomesKeyOnlyIfNeeded = true
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.contentView = contentView
    panel.setAccessibilityLabel("Mien 权限指引")

    contentView.onClose = { [weak self] in self?.close(returnToPreviousApplication: true) }
    contentView.onReopenSettings = { [weak self] in self?.reopenSettings() }
    contentView.onDragStateChange = { [weak self] isDragging in
      self?.setDragging(isDragging)
    }
    panel.onInteraction = { [weak self] in self?.keepSettingsVisible() }
  }

  func show(
    permission: DesktopPermission,
    applicationURL: URL,
    sourceFrame: CGRect,
    previousApplication: NSRunningApplication?
  ) {
    close(returnToPreviousApplication: false)
    self.permission = permission
    self.previousApplication = previousApplication
    contentView.configure(permission: permission, applicationURL: applicationURL)
    trackingStartedAt = Date()
    hasFoundSettingsWindow = false
    hasPresentedTarget = false
    hasActivatedSettings = false
    launchAnimationDeadline = .distantPast
    panel.alphaValue = 0.9
    panel.setFrame(
      SystemSettingsGuidePlacement.launchFrame(
        sourceFrame: sourceFrame,
        panelSize: Self.panelSize
      ),
      display: false
    )
    panel.orderFrontRegardless()
    startTracking()
    updateFrame()
  }

  func close() {
    close(returnToPreviousApplication: false)
  }

  private func close(returnToPreviousApplication: Bool) {
    timer?.invalidate()
    timer = nil
    permission = nil
    hasFoundSettingsWindow = false
    hasPresentedTarget = false
    hasActivatedSettings = false
    isDragging = false
    panel.ignoresMouseEvents = false
    panel.alphaValue = 1
    panel.orderOut(nil)
    if returnToPreviousApplication {
      previousApplication?.activate(options: [])
    }
    previousApplication = nil
    settingsApplication = nil
  }

  private func startTracking() {
    timer?.invalidate()
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.updateFrame() }
    }
    timer.tolerance = 0.025
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func updateFrame() {
    let applications = NSRunningApplication.runningApplications(
      withBundleIdentifier: Self.settingsBundleIdentifier
    )
    guard
      let application = applications.first(where: { $0.activationPolicy != .prohibited })
        ?? applications.first
    else {
      if hasFoundSettingsWindow || Date().timeIntervalSince(trackingStartedAt) > 8 {
        close(returnToPreviousApplication: hasFoundSettingsWindow)
      }
      return
    }
    settingsApplication = application
    if !hasActivatedSettings {
      hasActivatedSettings = true
      application.activate(options: [])
    }
    contentView.setSettingsFrontmost(NSWorkspace.shared.frontmostApplication == application)
    guard let settingsFrame = settingsWindowFrame(processIdentifier: application.processIdentifier)
    else { return }

    hasFoundSettingsWindow = true
    let screen = ScreenGeometry.current.first(where: { $0.appKitFrame.intersects(settingsFrame) })
    let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? settingsFrame
    let targetFrame = SystemSettingsGuidePlacement.frame(
      settingsFrame: settingsFrame,
      panelHeight: Self.panelSize.height,
      visibleFrame: visibleFrame
    )

    if !hasPresentedTarget {
      hasPresentedTarget = true
      let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      guard !reduceMotion else {
        panel.setFrame(targetFrame, display: true)
        panel.alphaValue = 1
        return
      }
      launchAnimationDeadline = Date().addingTimeInterval(0.2)
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().setFrame(targetFrame, display: true)
        panel.animator().alphaValue = 1
      }
      return
    }

    guard Date() >= launchAnimationDeadline, !isDragging else { return }
    guard panel.frame != targetFrame else { return }
    panel.setFrame(targetFrame, display: true)
  }

  private func setDragging(_ isDragging: Bool) {
    self.isDragging = isDragging
    panel.ignoresMouseEvents = isDragging
    panel.alphaValue = isDragging ? 0.72 : 1
    if isDragging {
      panel.orderBack(nil)
    } else {
      panel.orderFrontRegardless()
      keepSettingsVisible()
    }
  }

  private func keepSettingsVisible() {
    guard let settingsApplication, !settingsApplication.isActive else { return }
    DispatchQueue.main.async {
      settingsApplication.activate(options: [])
    }
  }

  private func reopenSettings() {
    guard let permission else { return }
    try? settingsRouter.open(permission)
    settingsApplication?.activate(options: [])
  }

  private func settingsWindowFrame(processIdentifier: pid_t) -> CGRect? {
    guard
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[String: Any]]
    else { return nil }

    return
      windows
      .filter { window in
        guard let owner = window[kCGWindowOwnerPID as String] as? pid_t else { return false }
        let layer = window[kCGWindowLayer as String] as? Int ?? 0
        let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
        return owner == processIdentifier && layer == 0 && alpha > 0
      }
      .compactMap { window -> CGRect? in
        guard
          let bounds = window[kCGWindowBounds as String] as? NSDictionary,
          let coreGraphicsFrame = CGRect(dictionaryRepresentation: bounds)
        else { return nil }
        return SystemSettingsWindowGeometry.appKitFrame(
          from: coreGraphicsFrame,
          screens: ScreenGeometry.current
        )
      }
      .filter { $0.width > 320 && $0.height > 240 }
      .max { $0.width * $0.height < $1.width * $1.height }
  }
}

struct SystemSettingsWindowGeometry {
  static func appKitFrame(
    from coreGraphicsFrame: CGRect,
    screens: [ScreenGeometry]
  ) -> CGRect? {
    let matchingScreens = screens.filter {
      $0.coreGraphicsFrame.intersects(coreGraphicsFrame)
    }
    guard
      let screen = matchingScreens.max(by: {
        $0.coreGraphicsFrame.intersection(coreGraphicsFrame).width
          * $0.coreGraphicsFrame.intersection(coreGraphicsFrame).height
          < $1.coreGraphicsFrame.intersection(coreGraphicsFrame).width
          * $1.coreGraphicsFrame.intersection(coreGraphicsFrame).height
      })
    else { return nil }
    return try? CoordinateTransformer().appKitRect(
      from: ScreenRect(
        x: coreGraphicsFrame.minX,
        y: coreGraphicsFrame.minY,
        width: coreGraphicsFrame.width,
        height: coreGraphicsFrame.height
      ),
      displayID: screen.displayID,
      screens: screens
    )
  }
}

@MainActor
public enum PermissionGuidePreviewRenderer {
  public static func png(appearance: NSAppearance.Name = .aqua) throws -> Data {
    let size = NSSize(width: 570, height: 132)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.appearance = NSAppearance(named: appearance)
    let content = SystemSettingsGuideContentView(
      applicationURL: URL(fileURLWithPath: "/Applications/Mien.app")
    )
    guard
      let icon = NSImage(
        contentsOfFile:
          FileManager.default.currentDirectoryPath + "/Resources/AppIcon/mien-1024.png"
      )
    else { throw CocoaError(.fileReadNoSuchFile) }
    content.setApplicationIcon(icon)
    content.setSettingsFrontmost(true)
    content.frame = NSRect(origin: .zero, size: size)
    window.contentView = content
    window.layoutIfNeeded()
    content.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    guard let representation = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
      throw CocoaError(.fileWriteUnknown)
    }
    content.cacheDisplay(in: content.bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    return data
  }
}
