import AppKit
import CoreGraphics
import Foundation
import MienContracts
import OSLog
import PermissionKernel
import QuartzCore

enum MienReadinessWindowPolicy {
  static let collectionBehavior: NSWindow.CollectionBehavior = [
    .canJoinAllSpaces, .fullScreenAuxiliary,
  ]

  static func frame(
    contentSize: NSSize,
    visibleFrames: [NSRect],
    pointer: NSPoint
  ) -> NSRect? {
    guard
      let visibleFrame = visibleFrames.first(where: { NSMouseInRect(pointer, $0, false) })
        ?? visibleFrames.first
    else { return nil }
    return NSRect(
      x: visibleFrame.midX - contentSize.width / 2,
      y: visibleFrame.midY - contentSize.height / 2,
      width: contentSize.width,
      height: contentSize.height
    )
  }
}

@MainActor
public final class MienReadinessController: NSObject, NSWindowDelegate {
  private enum Introduction {
    static let key = "mien-readiness.introduction.seen.v1"
  }

  private let permissionCoordinator: DesktopPermissionCoordinator
  private let settingsRouter: DesktopPermissionSettingsRouter
  private let defaults: UserDefaults
  private let modelPreferenceStore: AgentModelPreferenceStore
  private let guideController = SystemSettingsGuideController()
  private let logger = Logger(
    subsystem: "io.github.kohoj.mien",
    category: "readiness"
  )

  private var windowController: NSWindowController?
  private var contentController: (any ReadinessContent)?
  private var mode: ReadinessMode?
  private var activeObserver: NSObjectProtocol?
  private var refreshTimer: Timer?
  private var readiness: DesktopPermissionReadiness
  private var agent: AgentConnectionReadiness = .checking
  private var models: AgentModelReadiness

  public var onReadinessChange: ((Bool) -> Void)?
  public var onConnectAgent: (() -> Void)?
  public var onRefreshModels: (() -> Void)?

  public init(
    permissionCoordinator: DesktopPermissionCoordinator = DesktopPermissionCoordinator(),
    settingsRouter: DesktopPermissionSettingsRouter = DesktopPermissionSettingsRouter(),
    defaults: UserDefaults = .standard,
    modelPreferenceStore: AgentModelPreferenceStore? = nil
  ) {
    self.permissionCoordinator = permissionCoordinator
    self.settingsRouter = settingsRouter
    self.defaults = defaults
    let modelPreferenceStore = modelPreferenceStore ?? AgentModelPreferenceStore(defaults: defaults)
    self.modelPreferenceStore = modelPreferenceStore
    models = .notLoaded(preferredModelID: modelPreferenceStore.modelID)
    readiness = permissionCoordinator.readiness()
    super.init()
  }

  public var canUse: Bool { snapshot.canUse }
  public var isVisible: Bool { windowController?.window?.isVisible == true }
  public var requiresAttention: Bool { !snapshot.canUse }

  public func apply(agent: AgentConnectionReadiness) {
    self.agent = agent
    project()
    if activeObserver != nil,
      !isVisible,
      MienOnboardingDecision.shouldPresent(
        hasSeenIntroduction: defaults.bool(forKey: Introduction.key),
        readiness: snapshot
      )
    {
      showSetup()
    }
    startRefreshingIfNeeded()
  }

  public func beginLoadingAgentModels() {
    models = .loading(preferredModelID: modelPreferenceStore.modelID)
    project()
  }

  public func apply(modelCatalog: AgentModelCatalog) {
    guard (try? modelCatalog.validate()) != nil else {
      failAgentModelLoading()
      return
    }
    models = .available(
      catalog: modelCatalog,
      preferredModelID: modelPreferenceStore.modelID
    )
    project()
  }

  public func failAgentModelLoading() {
    models = .failed(preferredModelID: modelPreferenceStore.modelID)
    project()
  }

  public func start() {
    guard activeObserver == nil else { return }
    activeObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refresh() }
    }
    refresh()
    let hasSeenIntroduction = defaults.bool(forKey: Introduction.key)
    guard
      MienOnboardingDecision.shouldPresent(
        hasSeenIntroduction: hasSeenIntroduction,
        readiness: snapshot
      )
    else { return }
    logger.info(
      "presenting readiness agentConnected=\(self.agent.isConnected) accessibility=\(self.readiness.accessibility.rawValue, privacy: .public) screenRecording=\(self.readiness.screenRecording.rawValue, privacy: .public)"
    )
    showSetup()
  }

  public func stop() {
    stopRefreshing()
    guideController.close()
    if let activeObserver {
      NotificationCenter.default.removeObserver(activeObserver)
      self.activeObserver = nil
    }
    windowController?.close()
    windowController = nil
    contentController = nil
  }

  public func show(focusing permission: DesktopPermission? = nil) {
    present(mode: .settings, focusing: permission)
  }

  public func showSetup() { present(mode: .setup) }

  private func present(mode: ReadinessMode, focusing permission: DesktopPermission? = nil) {
    refresh()
    let content = ensureWindow(mode: mode)
    NSApp.activate(ignoringOtherApps: true)
    windowController?.showWindow(nil)
    windowController?.window?.makeKeyAndOrderFront(nil)
    content.focus(permission)
    startRefreshing()
    if mode == .settings, agent.isConnected { onRefreshModels?() }
  }

  public func windowWillClose(_ notification: Notification) {
    stopRefreshing()
    guideController.close()
  }

  private func project() {
    contentController?.apply(snapshot)
    onReadinessChange?(snapshot.canUse)
  }

  private func ensureWindow(mode: ReadinessMode) -> any ReadinessContent {
    if self.mode == mode, let contentController { return contentController }
    let actions = ReadinessActions(
      connect: { [weak self] in self?.onConnectAgent?() },
      refreshModels: { [weak self] in self?.onRefreshModels?() },
      selectModel: { [weak self] modelID in self?.selectAgentModel(modelID) },
      request: { [weak self] permission, source in
        guard let window = source.window else { return }
        self?.beginAuthorization(
          permission,
          sourceFrame: window.convertToScreen(source.convert(source.bounds, to: nil)))
      },
      finish: { [weak self] in self?.finish() },
      showSetup: { [weak self] in self?.showSetup() },
      showSettings: { [weak self] in self?.show() })
    let content: any ReadinessContent =
      switch mode {
      case .setup: MienSetupViewController(actions: actions)
      case .settings: MienSettingsViewController(actions: actions)
      }
    content.controller.preferredContentSize = mode.contentSize
    content.apply(snapshot)
    let window =
      (windowController?.window as? ReadinessWindow)
      ?? ReadinessWindow(
        contentRect: NSRect(origin: .zero, size: mode.contentSize),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = mode == .settings ? "Mien 设置" : "Mien"
    window.backgroundColor = MienAppearance.paper
    window.titlebarAppearsTransparent = mode == .setup
    window.titleVisibility = mode == .setup ? .hidden : .visible
    window.isReleasedWhenClosed = false
    window.collectionBehavior = MienReadinessWindowPolicy.collectionBehavior
    window.contentViewController = content.controller
    window.setContentSize(mode.contentSize)
    window.contentMinSize = mode.contentSize
    window.delegate = self
    window.onSettings = { [weak self] in self?.show() }
    if let frame = MienReadinessWindowPolicy.frame(
      contentSize: window.frame.size,
      visibleFrames: NSScreen.screens.map(\.visibleFrame), pointer: NSEvent.mouseLocation)
    {
      window.setFrame(frame, display: false)
    } else {
      window.center()
    }
    window.setAccessibilityLabel(mode == .setup ? "开始使用 Mien" : "Mien 设置")
    self.mode = mode
    self.contentController = content
    windowController = NSWindowController(window: window)
    return content
  }

  private func beginAuthorization(_ permission: DesktopPermission, sourceFrame: CGRect) {
    logger.info("permission guidance started permission=\(permission.rawValue, privacy: .public)")
    let previousApplication = NSWorkspace.shared.frontmostApplication
    do {
      try settingsRouter.open(permission)
      let applicationURL = Bundle.main.bundleURL
      guard applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
        throw SystemSettingsGuideError.applicationBundleUnavailable(applicationURL)
      }
      guideController.show(
        permission: permission,
        applicationURL: applicationURL,
        sourceFrame: sourceFrame,
        previousApplication: previousApplication
      )
      logger.info(
        "opened System Settings permission=\(permission.rawValue, privacy: .public) route=\(permission.settingsRoute.anchor, privacy: .public)"
      )
    } catch {
      contentController?.showNavigationError(for: permission)
      logger.error(
        "System Settings navigation failed permission=\(permission.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)"
      )
    }
  }

  private func refresh() {
    let previous = readiness
    readiness = permissionCoordinator.readiness()
    if previous != readiness {
      project()
      logger.info(
        "permission state changed accessibility=\(self.readiness.accessibility.rawValue, privacy: .public) screenRecording=\(self.readiness.screenRecording.rawValue, privacy: .public)"
      )
    }
    if let guidedPermission = guideController.permission,
      readiness.status(for: guidedPermission) == .authorized
    {
      guideController.close()
    }
    onReadinessChange?(snapshot.canUse)
    if readiness.isReady { stopRefreshing() }
  }

  private func finish() {
    refresh()
    guard snapshot.canUse else { return }
    defaults.set(true, forKey: Introduction.key)
    logger.info("Mien readiness introduction completed")
    windowController?.close()
  }

  private func selectAgentModel(_ modelID: String?) {
    if let modelID {
      guard case .available(let catalog, _) = models,
        catalog.contains(modelID)
      else {
        NSSound.beep()
        return
      }
    }
    modelPreferenceStore.setModelID(modelID)
    models = models.selecting(modelID)
    project()
    logger.info(
      "agent model selected source=user modelID=\(modelID ?? "agent-default", privacy: .public)"
    )
  }

  private func startRefreshing() {
    guard refreshTimer == nil, !readiness.isReady else { return }
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refresh() }
    }
    timer.tolerance = 0.2
    RunLoop.main.add(timer, forMode: .common)
    refreshTimer = timer
  }

  private func stopRefreshing() {
    refreshTimer?.invalidate()
    refreshTimer = nil
  }

  private func startRefreshingIfNeeded() {
    guard isVisible else { return }
    startRefreshing()
  }

  private var snapshot: MienReadinessSnapshot {
    MienReadinessSnapshot(agent: agent, models: models, permissions: readiness)
  }
}
