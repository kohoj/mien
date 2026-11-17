import AppKit
import HostRuntime
import InteractionShell
import OSLog

@MainActor
final class MienApplicationController {
  private var controller: InteractionController?
  private var conversation: MienConversationController?
  private var agentBridge: PiAgentBridge?
  private var startupTask: Task<Void, Never>?
  private var loginTask: Task<Void, Never>?
  private var modelRefreshTask: Task<Void, Never>?
  private var loginCoordinator: CodexDeviceLoginCoordinator?
  private var isStopping = false
  private let modelPreferenceStore = AgentModelPreferenceStore()
  private let bootstrap = MienRuntimeBootstrap(
    bundleURL: Bundle.main.bundleURL,
    resourceURL: Bundle.main.resourceURL, environment: ProcessInfo.processInfo.environment)
  private let logger = Logger(subsystem: "io.github.kohoj.mien", category: "application")

  func start() {
    guard startupTask == nil, !isStopping else { return }
    let start = ContinuousClock.now
    let controller = InteractionController(modelPreferenceStore: modelPreferenceStore)
    self.controller = controller
    controller.setAgentReadiness(.checking)
    controller.onConnectAgent = { [weak self] in self?.connectAgentFromOnboarding() }
    controller.onRefreshAgentModels = { [weak self] in self?.refreshAgentModels() }
    do { try controller.start() } catch {
      showStartupFailure(error)
      return
    }
    logger.info(
      "interface_ready elapsed=\(String(describing: start.duration(to: .now)), privacy: .public)")
    startupTask = Task { [weak self] in
      guard let self else { return }
      do {
        let runtime = try await self.bootstrap.prepare()
        try Task.checkCancellation()
        guard !self.isStopping else { return }
        self.agentBridge = runtime.agentBridge
        let conversation = MienConversationController(
          runtime: runtime, controller: controller, preferences: self.modelPreferenceStore)
        self.conversation = conversation
        conversation.onConnectAgent = { [weak self] in self?.connectAgentFromOnboarding() }
        controller.onSubmit = { [weak conversation] intent, snapshot in
          conversation?.submit(intent: intent, snapshot: snapshot)
        }
        controller.onDismiss = { [weak self, weak conversation] in
          self?.loginTask?.cancel()
          conversation?.dismiss()
        }
        controller.onResultAction = { [weak conversation] in conversation?.handleResultAction($0) }
        controller.setAgentReadiness(runtime.readiness)
        self.refreshAgentModels()
        self.logger.info(
          "host_ready elapsed=\(String(describing: start.duration(to: .now)), privacy: .public)")
      } catch is CancellationError { return } catch { self.showStartupFailure(error) }
    }
  }

  func stop() async {
    guard !isStopping else { return }
    isStopping = true
    controller?.stop()
    startupTask?.cancel()
    loginTask?.cancel()
    modelRefreshTask?.cancel()
    conversation?.dismiss()
    await startupTask?.value
    await loginTask?.value
    await modelRefreshTask?.value
    await conversation?.waitForIdle()
    await loginCoordinator?.cancel()
    await agentBridge?.stop()
  }

  private func showStartupFailure(_ error: Error) {
    logger.error("startup_failed error=\(String(describing: error), privacy: .public)")
    controller?.setAgentReadiness(.unavailable)
    let alert = NSAlert()
    alert.messageText = "Mien 未能完成启动"
    alert.informativeText = "本地数据或运行时检查失败。请退出后重试；错误已记录在系统日志中。"
    alert.alertStyle = .critical
    alert.addButton(withTitle: "退出 Mien")
    alert.runModal()
    NSApp.terminate(nil)
  }

  private func connectAgentFromOnboarding() {
    guard loginTask == nil, conversation != nil, !isStopping else { return }
    let refresh = modelRefreshTask
    refresh?.cancel()
    controller?.setAgentReadiness(.connecting)
    loginTask = Task { [weak self] in
      await refresh?.value
      await self?.conversation?.waitForIdle()
      guard let self else { return }
      defer { self.loginTask = nil }
      guard !Task.isCancelled else { return }
      await self.loginCodexAndResume()
    }
  }

  private func refreshAgentModels() {
    guard modelRefreshTask == nil, loginTask == nil, !isStopping, let agentBridge else { return }
    modelRefreshTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.modelRefreshTask = nil }
      await self.verifyAgentConnection(agentBridge)
    }
  }

  @discardableResult
  private func verifyAgentConnection(_ bridge: PiAgentBridge) async -> Bool {
    let start = ContinuousClock.now
    controller?.setAgentReadiness(.connecting)
    controller?.beginLoadingAgentModels()
    do {
      _ = try await bridge.connect()
      try Task.checkCancellation()
      guard !isStopping else { return false }
      controller?.setAgentReadiness(.connected(agentName: "已连接"))
      do {
        let catalog = try await bridge.discoverModels()
        try Task.checkCancellation()
        controller?.setAgentModelCatalog(catalog)
        logger.info(
          "agent_ready elapsed=\(String(describing: start.duration(to: .now)), privacy: .public)")
      } catch is CancellationError {
        return false
      } catch {
        if error as? PiAgentBridgeError == .authenticationRequired { throw error }
        controller?.setAgentModelLoadingFailed()
        logger.error(
          "live model catalog unavailable error=\(String(describing: error), privacy: .public)"
        )
        return false
      }
      return true
    } catch is CancellationError {
      return false
    } catch {
      guard !Task.isCancelled, !isStopping else { return false }
      if error as? PiAgentBridgeError == .authenticationRequired {
        controller?.setAgentReadiness(.authenticationRequired)
        controller?.showPermissionOnboarding()
        logger.error("agent connection requires Codex authentication")
      } else {
        controller?.setAgentReadiness(.failed)
      }
      return false
    }
  }

  private func loginCodexAndResume() async {
    do {
      controller?.setAgentReadiness(.connecting)
      guard let coordinator = try await bootstrap.makeLoginCoordinator() else {
        throw CodexDeviceLoginError.invalidConfiguration
      }
      loginCoordinator = coordinator
      try await coordinator.authenticate { [weak self] authorization in
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard let self, !self.isStopping else { return }
          NSWorkspace.shared.open(authorization.verificationURL)
          self.controller?.setAgentReadiness(
            .awaitingAuthorization(code: authorization.userCode)
          )
        }
      }
      try Task.checkCancellation()
      loginCoordinator = nil
      if agentBridge == nil {
        agentBridge = await bootstrap.makeAgentBridge(
          applicationSupportURL: try await bootstrap.applicationSupportDirectory())
      }
      guard let agentBridge else { throw CodexDeviceLoginError.invalidCredential }
      guard await verifyAgentConnection(agentBridge) else {
        throw CodexDeviceLoginError.invalidCredential
      }
      try Task.checkCancellation()
      conversation?.resumeAfterAuthentication(using: agentBridge)
    } catch is CancellationError {
      loginCoordinator = nil
    } catch {
      loginCoordinator = nil
      guard !Task.isCancelled else { return }
      controller?.setAgentReadiness(.failed)
      controller?.showPermissionOnboarding()
      NSSound.beep()
    }
  }

}
