import AppKit
import Foundation
import InvocationKernel
import MienContracts

@MainActor
public final class InteractionController {
  public var onSubmit: ((String, InvocationSnapshot) -> Void)?
  public var onDismiss: (() -> Void)?
  public var onResultAction: ((TaskPresentationAction) -> Void)?

  private let shortcutRegistrar: GlobalShortcutRegistrar
  private let resolver: InvocationResolver
  private let overlay: OverlayCoordinator
  private let activityMonitor = UserActivityMonitor()
  private let taskCenter = TaskCenterController()
  private var userInputEpoch: UInt64 = 0
  private var invocationTask: Task<Void, Never>?
  private var latestPresentation: TaskPresentation?
  private var backgroundCompletionSafe = false

  public init(
    shortcutRegistrar: GlobalShortcutRegistrar = GlobalShortcutRegistrar(),
    resolver: InvocationResolver = InvocationResolver(),
    overlay: OverlayCoordinator = OverlayCoordinator()
  ) {
    self.shortcutRegistrar = shortcutRegistrar
    self.resolver = resolver
    self.overlay = overlay
    shortcutRegistrar.onPress = { [weak self] in self?.toggle() }
    overlay.onSubmit = { [weak self] intent, snapshot in
      guard let self else { return }
      self.activityMonitor.start { [weak self] in self?.handleUserTakeover() }
      self.onSubmit?(intent, snapshot)
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
    taskCenter.onOpen = { [weak self] in self?.restoreDetachedTask() }
  }

  public func start(shortcut: GlobalShortcutRegistrar.Shortcut = .default) throws {
    try shortcutRegistrar.register(shortcut)
  }

  public func stop() {
    invocationTask?.cancel()
    activityMonitor.stop()
    taskCenter.hide()
    shortcutRegistrar.unregister()
    overlay.dismiss(notify: false)
  }

  public func setStatus(_ text: String, allowsRetry: Bool = false) {
    if allowsRetry { activityMonitor.stop() }
    overlay.setStatus(text, allowsRetry: allowsRetry)
    if overlay.hasSession, !overlay.isVisible {
      taskCenter.show(status: text, completed: false)
    }
  }

  public func showResult(_ text: String, status: String = "已完成") {
    activityMonitor.stop()
    overlay.showResult(text, status: status)
  }

  public func showActionPrompt(status: String, action: TaskPresentationAction) {
    activityMonitor.stop()
    overlay.showActionPrompt(status: status, action: action)
  }

  public func bind(taskID: UUID) {
    overlay.bind(taskID: taskID)
    latestPresentation = nil
  }

  public func disclose(_ manifest: ContextManifest) {
    overlay.setContextDisclosure(ContextDisclosureFormatter().label(for: manifest))
  }

  public func present(_ presentation: TaskPresentation) {
    if presentation.result != nil || presentation.allowsRetry { activityMonitor.stop() }
    latestPresentation = presentation
    if overlay.isVisible {
      overlay.present(presentation)
    } else if overlay.hasSession {
      taskCenter.show(
        status: presentation.status,
        completed: presentation.result != nil || presentation.allowsRetry
      )
    }
  }

  public func allowBackgroundCompletion() {
    backgroundCompletionSafe = true
    activityMonitor.start { [weak self] in self?.detachCurrentTask() }
  }

  private func handleUserTakeover() {
    overlay.dismiss(notify: false)
    onDismiss?()
  }

  private func detachCurrentTask() {
    guard backgroundCompletionSafe, overlay.isVisible else { return }
    overlay.detach()
    taskCenter.show(
      status: latestPresentation?.status ?? "Codex 正在处理…",
      completed: false
    )
  }

  private func restoreDetachedTask() {
    guard overlay.hasSession else { return }
    taskCenter.hide()
    overlay.restore()
    if let latestPresentation { overlay.present(latestPresentation) }
    if backgroundCompletionSafe, latestPresentation?.result == nil {
      activityMonitor.start { [weak self] in self?.detachCurrentTask() }
    }
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
    invocationTask?.cancel()
    userInputEpoch &+= 1
    guard let location = CGEvent(source: nil)?.location else {
      NSSound.beep()
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
        NSSound.beep()
      }
    }
  }
}
