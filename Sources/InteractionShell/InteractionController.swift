import AppKit
import Foundation
import InvocationKernel
import MienContracts
import OSLog
import PermissionKernel

enum InvocationFeedback {
  static func message(for error: Error) -> String {
    switch error as? InvocationResolutionError {
    case .targetChanged: "窗口已变化。回到你要处理的窗口，再次唤起 Mien。"
    case .noDisplayAtPointer, .invalidPointer: "无法确定当前屏幕。把光标移到应用窗口中，再试一次。"
    case .noWindowAtPointer, .missingBundleIdentifier: "先打开一个应用窗口，再按快捷键提问。"
    case nil: "无法确认当前窗口。回到应用窗口，再次唤起 Mien。"
    }
  }
}

@MainActor
public final class InteractionController {
  public var onSubmit: ((String, InvocationSnapshot) -> Void)?
  public var onDismiss: (() -> Void)?
  public var onResultAction: ((TaskPresentationAction) -> Void)?
  public var onConnectAgent: (() -> Void)?
  public var onRefreshAgentModels: (() -> Void)?

  private let shortcutRegistrar: GlobalShortcutRegistrar
  private let resolver: InvocationResolver
  private let overlay: OverlayCoordinator
  private let activityMonitor = UserActivityMonitor()
  private let taskCenter = TaskCenterController()
  private let readinessController: MienReadinessController
  private var userInputEpoch: UInt64 = 0
  private var invocationTask: Task<Void, Never>?
  private var submissionTask: Task<Void, Never>?
  private var latestPresentation: TaskPresentation?
  private var backgroundCompletionSafe = false

  public init(
    shortcutRegistrar: GlobalShortcutRegistrar = GlobalShortcutRegistrar(),
    resolver: InvocationResolver = InvocationResolver(),
    overlay: OverlayCoordinator = OverlayCoordinator(),
    modelPreferenceStore: AgentModelPreferenceStore = AgentModelPreferenceStore()
  ) {
    self.shortcutRegistrar = shortcutRegistrar
    self.resolver = resolver
    self.overlay = overlay
    readinessController = MienReadinessController(
      modelPreferenceStore: modelPreferenceStore
    )
    shortcutRegistrar.onPress = { [weak self] in self?.toggle() }
    overlay.onSubmit = { [weak self] intent, snapshot in
      self?.submit(intent: intent, anchoredTo: snapshot)
    }
    overlay.onDismiss = { [weak self] in
      self?.activityMonitor.stop()
      self?.taskCenter.hide()
      self?.latestPresentation = nil
      self?.backgroundCompletionSafe = false
      self?.onDismiss?()
    }
    overlay.onResultAction = { [weak self] action in
      self?.onResultAction?(action)
    }
    taskCenter.onOpen = { [weak self] in self?.openFromMenuBar() }
    taskCenter.onReadiness = { [weak self] in self?.readinessController.show() }
    taskCenter.onQuit = { NSApp.terminate(nil) }
    taskCenter.hasConversation = { [weak self] in self?.overlay.hasSession ?? false }
    readinessController.onConnectAgent = { [weak self] in self?.onConnectAgent?() }
    readinessController.onRefreshModels = { [weak self] in self?.onRefreshAgentModels?() }
    readinessController.onReadinessChange = { [weak self] in self?.taskCenter.setReady($0) }
    overlay.onSettings = { [weak self] in self?.readinessController.show() }
  }

  public func start(shortcut: GlobalShortcutRegistrar.Shortcut = .default) throws {
    try shortcutRegistrar.register(shortcut)
    taskCenter.install(shortcutDescription: shortcut.displayName)
    readinessController.start()
  }

  public func stop() {
    invocationTask?.cancel()
    submissionTask?.cancel()
    activityMonitor.stop()
    readinessController.stop()
    taskCenter.remove()
    shortcutRegistrar.unregister()
    overlay.dismiss(notify: false)
  }

  private func submit(intent: String, anchoredTo snapshot: InvocationSnapshot) {
    submissionTask?.cancel()
    userInputEpoch &+= 1
    let epoch = userInputEpoch
    activityMonitor.start(
      ownedWindows: interactionWindows,
      onActivity: { [weak self] in self?.handleUserTakeover() }
    )
    let resolver = resolver
    submissionTask = Task {
      do {
        let renewed = try await Task.detached(priority: .userInitiated) {
          try resolver.renew(snapshot, userInputEpoch: epoch)
        }.value
        try Task.checkCancellation()
        onSubmit?(intent, renewed)
      } catch is CancellationError {
        return
      } catch {
        activityMonitor.stop()
        overlay.setStatus("原窗口已变化 · 请重新唤起 Mien", allowsRetry: true)
        NSSound.beep()
      }
    }
  }

  public func setStatus(_ text: String, allowsRetry: Bool = false) {
    if allowsRetry { activityMonitor.stop() }
    overlay.setStatus(text, allowsRetry: allowsRetry)
    if overlay.hasSession, !overlay.isVisible {
      taskCenter.show(status: text, completed: false)
    }
  }

  public func showResult(
    _ text: String,
    status: String = "已完成",
    outcome: TaskPresentationOutcome = .success
  ) {
    activityMonitor.stop()
    overlay.showResult(text, status: status, outcome: outcome)
  }

  public func showActionPrompt(status: String, action: TaskPresentationAction) {
    activityMonitor.stop()
    overlay.showActionPrompt(status: status, action: action)
  }

  public func resumeAfterAuthentication() {
    latestPresentation = nil
    backgroundCompletionSafe = false
    overlay.resumeAfterAuthentication()
  }

  public func invalidateConversation(status: String) {
    activityMonitor.stop()
    latestPresentation = nil
    backgroundCompletionSafe = false
    overlay.invalidateConversation(status: status)
  }

  public func showPermissionOnboarding(focusing permission: DesktopPermission? = nil) {
    if let permission {
      readinessController.show(focusing: permission)
    } else {
      readinessController.showSetup()
    }
  }

  public func setAgentReadiness(_ readiness: AgentConnectionReadiness) {
    readinessController.apply(agent: readiness)
  }

  public func beginLoadingAgentModels() {
    readinessController.beginLoadingAgentModels()
  }

  public func setAgentModelCatalog(_ catalog: AgentModelCatalog) {
    readinessController.apply(modelCatalog: catalog)
  }

  public func setAgentModelLoadingFailed() {
    readinessController.failAgentModelLoading()
  }

  public func bind(taskID: UUID) {
    overlay.bind(taskID: taskID)
    latestPresentation = nil
  }

  public func presentAgentActivity(_ presentation: AgentActivityPresentation) {
    overlay.presentActivity(presentation)
  }

  public func disclose(_ manifest: ContextManifest) {
    overlay.setContextDisclosure(ContextDisclosureFormatter().label(for: manifest))
  }

  public func present(_ presentation: TaskPresentation) {
    if presentation.result != nil || presentation.allowsRetry || presentation.action != nil {
      activityMonitor.stop()
    }
    latestPresentation = presentation
    if overlay.isVisible {
      overlay.present(presentation)
    } else if overlay.hasSession {
      taskCenter.show(
        status: presentation.status,
        completed: presentation.result != nil || presentation.allowsRetry
          || presentation.action != nil
      )
    }
  }

  public func allowBackgroundCompletion() {
    backgroundCompletionSafe = true
    activityMonitor.start(
      ownedWindows: interactionWindows,
      onActivity: { [weak self] in self?.detachCurrentTask() }
    )
  }

  private func handleUserTakeover() {
    overlay.dismiss(notify: false)
    onDismiss?()
  }

  private func detachCurrentTask() {
    guard backgroundCompletionSafe, overlay.isVisible else { return }
    overlay.detach()
    taskCenter.show(
      status: latestPresentation?.status ?? "正在整理回答…",
      completed: false
    )
  }

  /// Clicking the menu bar item resumes a detached task if there is one, and
  /// otherwise opens a composer targeting the frontmost window. It cannot take
  /// the pointer path: the cursor is over the menu bar, which sits above every
  /// application window, so no target would ever be found there.
  private func openFromMenuBar() {
    if overlay.hasSession {
      restoreDetachedTask()
      return
    }
    guard readinessController.canUse else {
      readinessController.showSetup()
      return
    }
    invocationTask?.cancel()
    userInputEpoch &+= 1
    let epoch = userInputEpoch
    let resolver = resolver
    invocationTask = Task {
      do {
        let snapshot = try await Task.detached(priority: .userInitiated) {
          try resolver.resolveFrontmost(userInputEpoch: epoch)
        }.value
        try Task.checkCancellation()
        try overlay.show(snapshot: snapshot)
      } catch is CancellationError {
        return
      } catch {
        showInvocationFailure(error)
      }
    }
  }

  private func restoreDetachedTask() {
    guard overlay.hasSession else { return }
    taskCenter.hide()
    overlay.restore()
    if let latestPresentation { overlay.present(latestPresentation) }
    if backgroundCompletionSafe, latestPresentation?.result == nil {
      activityMonitor.start(
        ownedWindows: interactionWindows,
        onActivity: { [weak self] in self?.detachCurrentTask() }
      )
    }
  }

  /// The overlay owns both its interactive transcript panel and its
  /// mouse-transparent semantic lens. Passing their exact window identities to
  /// `UserActivityMonitor` keeps event filtering independent of titles, view
  /// hierarchy, and whichever panel happens to be key.
  private var interactionWindows: [NSWindow] {
    NSApp.windows.filter { $0 is NonactivatingPanel }
  }

  private func toggle() {
    if overlay.hasSession, !overlay.isVisible {
      restoreDetachedTask()
      return
    }
    if overlay.isVisible {
      overlay.dismiss()
      return
    }
    guard readinessController.canUse else {
      readinessController.showSetup()
      return
    }
    invocationTask?.cancel()
    userInputEpoch &+= 1
    guard let location = CGEvent(source: nil)?.location else {
      showInvocationFailure(InvocationResolutionError.invalidPointer)
      return
    }
    let pointer = ScreenPoint(x: location.x, y: location.y)
    let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    let epoch = userInputEpoch
    let resolver = resolver
    invocationTask = Task {
      do {
        let snapshot = try await Task.detached(priority: .userInitiated) {
          try resolver.resolve(
            pointer: pointer,
            frontmostProcessIdentifier: frontmostPID,
            userInputEpoch: epoch
          )
        }.value
        try Task.checkCancellation()
        try overlay.show(snapshot: snapshot)
      } catch is CancellationError {
        return
      } catch {
        showInvocationFailure(error)
      }
    }
  }

  private func showInvocationFailure(_ error: Error) {
    Logger(subsystem: "io.github.kohoj.mien", category: "invocation").error(
      "invocation_failed error=\(String(describing: error), privacy: .public)")
    taskCenter.showInvocationFailure(InvocationFeedback.message(for: error))
  }
}
