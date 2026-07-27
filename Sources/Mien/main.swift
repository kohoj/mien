import ACPGateway
import ActionKernel
import AppKit
import ArtifactStore
import ContextKernel
import DesktopActionAdapters
import HostRuntime
import InteractionShell
import MienContracts
import PermissionKernel
import PolicyKernel
import ProviderAdapters
import TaskRuntime

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
  private struct RuntimeDigests: Decodable {
    let codexACP: String
    let codex: String
    let longview: String
  }

  private struct PendingDraft {
    let taskID: UUID
    let window: WindowLease
    let element: AXElementFingerprint
    let result: String
    let sensitivity: Sensitivity
    let desktopRecoveryVerified: Bool
  }

  private struct PendingUndo {
    let taskID: UUID
    let result: String
    let reference: String
    let desktopRecoveryVerified: Bool
  }

  private struct PendingLoginRequest {
    let intent: String
    let snapshot: InvocationSnapshot
  }

  private var controller: InteractionController?
  private var coordinator: DesktopTaskCoordinator?
  private var artifactStore: PrivateArtifactStore?
  private var agentBridge: CodexAgentBridge?
  private var longviewProvider: LongviewContextProvider?
  private var task: Task<Void, Never>?
  private var terminationInProgress = false
  private var agentUnavailableStatus = "Agent 运行时未安装"
  private let draftExecutor = AXDraftExecutor()
  private lazy var actionBroker = ActionBroker(executors: [draftExecutor])
  private var pendingDraft: PendingDraft?
  private var pendingUndo: PendingUndo?
  private var undoFinalizer: Task<Void, Never>?
  private var pendingLoginRequest: PendingLoginRequest?
  private var loginCoordinator: CodexDeviceLoginCoordinator?

  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { @MainActor [weak self] in
      do {
        try await self?.startRuntime()
      } catch {
        NSApp.terminate(nil)
      }
    }
  }

  private func startRuntime() async throws {
    let supportURL = try applicationSupportDirectory()
    let journal = try JSONLTaskEventJournal(
      fileURL: supportURL.appendingPathComponent("task-events.jsonl")
    )
    try await recoverInterruptedTasks(journal: journal, supportURL: supportURL)
    let artifactsURL =
      supportURL
      .appendingPathComponent("Artifacts", isDirectory: true)
    let artifactStore = try PrivateArtifactStore(rootURL: artifactsURL)
    let coordinator = try DesktopTaskCoordinator(journal: journal)
    let controller = InteractionController()
    controller.onSubmit = { [weak self] intent, snapshot in
      self?.beginTask(intent: intent, snapshot: snapshot)
    }
    controller.onDismiss = { [weak self] in
      self?.handleDismiss()
    }
    controller.onResultAction = { [weak self] action in
      self?.handleResultAction(action)
    }
    try controller.start()
    self.controller = controller
    self.coordinator = coordinator
    self.artifactStore = artifactStore
    agentBridge = makeAgentBridge(applicationSupportURL: supportURL)
    longviewProvider = makeLongviewProvider(
      applicationSupportURL: supportURL,
      store: artifactStore
    )
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminationInProgress else { return .terminateLater }
    terminationInProgress = true
    controller?.stop()
    let activeTask = task
    activeTask?.cancel()
    let agentBridge = agentBridge
    Task {
      await activeTask?.value
      await self.finishPendingForTermination()
      await self.loginCoordinator?.cancel()
      await agentBridge?.stop()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  private func beginTask(intent: String, snapshot: InvocationSnapshot) {
    guard let coordinator, let artifactStore else { return }
    if agentBridge == nil, agentUnavailableStatus == "需要先登录 Codex" {
      pendingLoginRequest = PendingLoginRequest(intent: intent, snapshot: snapshot)
      controller?.showActionPrompt(status: "登录后继续当前任务", action: .loginCodex)
      return
    }
    let previousTask = task
    let agentBridge = agentBridge
    let requestedScope = ContextScopeInference().infer(intent: intent, snapshot: snapshot)
    task = Task { [weak self] in
      previousTask?.cancel()
      await previousTask?.value
      guard !Task.isCancelled else { return }
      self?.controller?.setStatus("正在读取上下文…")
      await self?.runTask(
        intent: intent,
        snapshot: snapshot,
        requestedScope: requestedScope,
        coordinator: coordinator,
        artifactStore: artifactStore,
        agentBridge: agentBridge
      )
    }
  }

  private func runTask(
    intent: String,
    snapshot: InvocationSnapshot,
    requestedScope: ContextScope,
    coordinator: DesktopTaskCoordinator,
    artifactStore: PrivateArtifactStore,
    agentBridge: CodexAgentBridge?
  ) async {
    var taskID: UUID?
    var agentStarted = false
    var desktopRecoveryVerified = true
    do {
      let prepared = try await coordinator.begin(
        intent: intent,
        snapshot: snapshot,
        requestedScope: requestedScope,
        allowedActions: [.read, .proposeDraft, .reversibleWrite]
      )
      taskID = prepared.capsule.id
      controller?.bind(taskID: prepared.capsule.id)
      await presentTask(taskID: prepared.capsule.id, coordinator: coordinator)
      let subject = PolicySubject(
        bundleIdentifier: prepared.targetLease.window.bundleIdentifier,
        windowID: prepared.targetLease.window.windowID,
        scope: requestedScope,
        protectedContent: prepared.targetLease.semanticTarget?.protectedContent == true
      )
      let preflightSensitivity = SurfaceSensitivityClassifier().classify(
        bundleIdentifier: subject.bundleIdentifier,
        semanticTarget: prepared.targetLease.semanticTarget
      )
      let accessibilityPolicy = PolicyEngine().evaluate(
        PolicyRequest(
          taskID: prepared.capsule.id,
          subject: subject,
          operation: .readAccessibility,
          sensitivity: preflightSensitivity,
          destination: .hostOnly,
          userInitiated: true
        ))
      guard case .allow = accessibilityPolicy else {
        try await coordinator.fail(
          taskID: prepared.capsule.id,
          reason: "context preflight policy denied the target"
        )
        _ = await finishCleanup(
          taskID: prepared.capsule.id,
          coordinator: coordinator,
          artifactStore: artifactStore
        )
        controller?.setStatus("此内容受保护")
        return
      }

      var providers: [any ContextProvider] = [
        SelectionContextProvider(snapshot: snapshot, store: artifactStore)
      ]
      let permissionCoordinator = DesktopPermissionCoordinator()
      let accessibilityStatus: DesktopPermissionStatus
      if requestedScope == .selection {
        accessibilityStatus = permissionCoordinator.status(for: .accessibility)
      } else {
        let current = permissionCoordinator.status(for: .accessibility)
        accessibilityStatus =
          current == .authorized ? current : permissionCoordinator.request(.accessibility)
      }
      if accessibilityStatus == .authorized {
        providers.append(AccessibilityContextProvider(store: artifactStore))
      }
      let pixelPolicy = PolicyEngine().evaluate(
        PolicyRequest(
          taskID: prepared.capsule.id,
          subject: subject,
          operation: .capturePixels,
          sensitivity: preflightSensitivity,
          destination: .hostOnly,
          userInitiated: true
        ))
      var screenRecordingStatus = permissionCoordinator.status(for: .screenRecording)
      if requestedScope == .boundedHistory,
        screenRecordingStatus != .authorized
      {
        screenRecordingStatus = permissionCoordinator.request(.screenRecording)
      }
      if case .allow = pixelPolicy,
        accessibilityStatus == .authorized,
        screenRecordingStatus == .authorized,
        let longviewProvider
      {
        providers.append(longviewProvider)
        desktopRecoveryVerified = false
      }
      let resolution = try await ContextBroker(providers: providers).resolve(
        prepared.contextRequest
      )
      let usedLongview = resolution.artifacts.contains { $0.provider == .longview }
      if usedLongview {
        desktopRecoveryVerified = resolution.receipts.contains {
          $0.executor == "LongviewAdapter" && $0.recovery.isClean
        }
      } else if requestedScope != .boundedHistory,
        resolution.resolvedScope == requestedScope
      {
        desktopRecoveryVerified = true
      }
      let sensitivity = max(
        preflightSensitivity,
        resolution.artifacts.map(\.sensitivity).max() ?? .publicData
      )
      let transmissionPolicy = PolicyEngine().evaluate(
        PolicyRequest(
          taskID: prepared.capsule.id,
          subject: subject,
          operation: .transmit,
          sensitivity: sensitivity,
          destination: .codex,
          userInitiated: true
        ))
      let remoteTransmissionAllowed: Bool
      if case .allow = transmissionPolicy {
        remoteTransmissionAllowed = true
      } else {
        remoteTransmissionAllowed = false
      }
      let manifest = try await coordinator.attachContext(
        resolution,
        to: prepared.capsule.id,
        remoteTransmissionAllowed: remoteTransmissionAllowed,
        desktopRecoveryVerified: desktopRecoveryVerified
      )
      controller?.disclose(manifest)
      try Task.checkCancellation()
      guard remoteTransmissionAllowed else {
        try await coordinator.fail(
          taskID: prepared.capsule.id,
          reason: "policy kept context inside the local trust boundary"
        )
        _ = await finishCleanup(
          taskID: prepared.capsule.id,
          coordinator: coordinator,
          artifactStore: artifactStore
        )
        controller?.setStatus("上下文仅在本机")
        return
      }
      guard let agentBridge else {
        try await coordinator.fail(
          taskID: prepared.capsule.id,
          reason: "pinned ACP runtime unavailable"
        )
        _ = await finishCleanup(
          taskID: prepared.capsule.id,
          coordinator: coordinator,
          artifactStore: artifactStore
        )
        controller?.setStatus(agentUnavailableStatus)
        return
      }

      controller?.allowBackgroundCompletion()
      controller?.setStatus("Codex 正在处理…")
      try await coordinator.markAgentRunning(taskID: prepared.capsule.id)
      await presentTask(taskID: prepared.capsule.id, coordinator: coordinator)
      agentStarted = true
      let workingDirectory = try taskWorkingDirectory(taskID: prepared.capsule.id)
      let result = try await agentBridge.run(
        capsule: prepared.capsule,
        manifest: manifest,
        artifactReader: artifactStore,
        workingDirectory: workingDirectory
      )
      try Task.checkCancellation()
      if result.stopReason == .endTurn, let mutationTarget = prepared.mutationTarget {
        try await coordinator.markAwaitingPermission(taskID: prepared.capsule.id)
        _ = await cleanupEphemeralData(
          taskID: prepared.capsule.id,
          artifactStore: artifactStore
        )
        pendingDraft = PendingDraft(
          taskID: prepared.capsule.id,
          window: prepared.targetLease.window,
          element: mutationTarget,
          result: result.text,
          sensitivity: sensitivity,
          desktopRecoveryVerified: desktopRecoveryVerified
        )
        await presentTask(
          taskID: prepared.capsule.id,
          coordinator: coordinator,
          result: result.text,
          action: .insertDraft
        )
        return
      }
      try await coordinator.completeReadOnly(
        taskID: prepared.capsule.id,
        succeeded: result.stopReason == .endTurn,
        reason: "ACP turn ended with \(result.stopReason.rawValue)"
      )
      let cleanupVerified = await finishCleanup(
        taskID: prepared.capsule.id,
        coordinator: coordinator,
        artifactStore: artifactStore,
        desktopRecoveryVerified: desktopRecoveryVerified
      )
      await presentTask(
        taskID: prepared.capsule.id,
        coordinator: coordinator,
        result: result.stopReason == .endTurn ? result.text : nil,
        cleanupVerified: cleanupVerified
      )
    } catch is CancellationError {
      if let taskID {
        try? await coordinator.cancel(
          taskID: taskID,
          reason: "user dismissed Mien"
        )
        _ = await finishCleanup(
          taskID: taskID,
          coordinator: coordinator,
          artifactStore: artifactStore,
          desktopRecoveryVerified: desktopRecoveryVerified
        )
      }
    } catch {
      if let taskID {
        if agentStarted {
          try? await coordinator.completeReadOnly(
            taskID: taskID,
            succeeded: false,
            reason: taskFailureReason(error)
          )
        } else {
          try? await coordinator.fail(taskID: taskID, reason: "task preparation failed")
        }
        _ = await finishCleanup(
          taskID: taskID,
          coordinator: coordinator,
          artifactStore: artifactStore,
          desktopRecoveryVerified: desktopRecoveryVerified
        )
        await presentTask(taskID: taskID, coordinator: coordinator)
        if agentStarted {
          controller?.setStatus(taskFailureStatus(error), allowsRetry: true)
        }
      }
      if taskID == nil {
        controller?.setStatus(
          agentStarted ? "Agent 未完成" : "上下文不可用",
          allowsRetry: true
        )
      }
      NSSound.beep()
    }
  }

  private func handleResultAction(_ action: TaskPresentationAction) {
    switch action {
    case .insertDraft:
      guard let pendingDraft, let coordinator, let artifactStore else { return }
      self.pendingDraft = nil
      let previousTask = task
      task = Task { [weak self] in
        await previousTask?.value
        guard let self else { return }
        await self.insertDraft(
          pendingDraft,
          coordinator: coordinator,
          artifactStore: artifactStore
        )
      }
    case .undoDraft:
      guard let pendingUndo, let coordinator, let artifactStore else { return }
      self.pendingUndo = nil
      undoFinalizer?.cancel()
      undoFinalizer = nil
      let previousTask = task
      task = Task { [weak self] in
        await previousTask?.value
        guard let self else { return }
        await self.undoDraft(
          pendingUndo,
          coordinator: coordinator,
          artifactStore: artifactStore
        )
      }
    case .loginCodex:
      guard let pendingLoginRequest else { return }
      task = Task { [weak self] in
        guard let self else { return }
        await self.loginCodexAndResume(pendingLoginRequest)
      }
    }
  }

  private func loginCodexAndResume(_ request: PendingLoginRequest) async {
    do {
      controller?.showResult("正在申请一次性设备代码…", status: "连接 Codex")
      guard let coordinator = try makeLoginCoordinator() else {
        throw CodexDeviceLoginError.invalidConfiguration
      }
      loginCoordinator = coordinator
      try await coordinator.authenticate { [weak self] authorization in
        await MainActor.run {
          guard let self else { return }
          NSWorkspace.shared.open(authorization.verificationURL)
          self.controller?.showResult(
            "在浏览器中输入一次性代码  \(authorization.userCode)",
            status: "等待浏览器确认…"
          )
        }
      }
      loginCoordinator = nil
      agentBridge = makeAgentBridge(applicationSupportURL: try applicationSupportDirectory())
      guard agentBridge != nil else { throw CodexDeviceLoginError.invalidCredential }
      pendingLoginRequest = nil
      task = nil
      controller?.setStatus("已登录 · 正在继续…")
      beginTask(intent: request.intent, snapshot: request.snapshot)
    } catch is CancellationError {
      loginCoordinator = nil
    } catch {
      loginCoordinator = nil
      controller?.showActionPrompt(status: "登录未完成 · 可重试", action: .loginCodex)
      NSSound.beep()
    }
  }

  private func insertDraft(
    _ pending: PendingDraft,
    coordinator: DesktopTaskCoordinator,
    artifactStore: PrivateArtifactStore
  ) async {
    do {
      controller?.setStatus("正在核对原输入框…")
      let now = Date()
      let proposal = try await draftExecutor.prepare(
        taskID: pending.taskID,
        window: pending.window,
        element: pending.element,
        scope: .pointedElement,
        draft: pending.result,
        now: now
      )
      let subject = PolicySubject(
        bundleIdentifier: proposal.target.window.bundleIdentifier,
        windowID: proposal.target.window.windowID,
        scope: .pointedElement,
        protectedContent: proposal.target.semanticTarget?.protectedContent == true
      )
      let policy = PolicyEngine().evaluate(
        PolicyRequest(
          taskID: pending.taskID,
          subject: subject,
          operation: .mutate,
          sensitivity: pending.sensitivity,
          destination: .externalApplication,
          userInitiated: true,
          approvalReference: "overlay-insert:\(proposal.id.uuidString)"
        ))
      let grant = CapabilityGrant(
        taskID: pending.taskID,
        targetLeaseID: proposal.target.id,
        exactToolName: draftExecutor.name,
        action: .reversibleWrite,
        scope: .pointedElement,
        issuedAt: now,
        expiresAt: min(proposal.target.expiresAt, now.addingTimeInterval(10)),
        maximumUses: 1,
        nonce: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        approvalReference: "overlay-insert:\(proposal.id.uuidString)"
      )
      try await coordinator.markExecuting(taskID: pending.taskID)
      controller?.setStatus("正在写入并读回验证…")
      let receipt = try await actionBroker.execute(
        proposal,
        grant: grant,
        policyDecision: policy
      )
      try await coordinator.markVerifying(taskID: pending.taskID)
      guard receipt.isVerifiedSuccess,
        let reference = receipt.inverseOperationReference
      else {
        try await coordinator.completeMutation(
          taskID: pending.taskID,
          succeeded: false,
          reason: "draft write did not produce a verified reversible receipt"
        )
        _ = await finishCleanup(
          taskID: pending.taskID,
          coordinator: coordinator,
          artifactStore: artifactStore,
          desktopRecoveryVerified: pending.desktopRecoveryVerified
        )
        controller?.showResult(pending.result, status: "未能验证写入")
        return
      }

      try await coordinator.markReversibleWindow(
        taskID: pending.taskID,
        receipt: receipt
      )
      let undo = PendingUndo(
        taskID: pending.taskID,
        result: pending.result,
        reference: reference,
        desktopRecoveryVerified: pending.desktopRecoveryVerified
      )
      pendingUndo = undo
      await presentTask(
        taskID: pending.taskID,
        coordinator: coordinator,
        result: pending.result,
        action: .undoDraft
      )
      scheduleUndoFinalization(undo, coordinator: coordinator, artifactStore: artifactStore)
    } catch {
      try? await coordinator.fail(
        taskID: pending.taskID,
        reason: draftFailureReason(error)
      )
      _ = await finishCleanup(
        taskID: pending.taskID,
        coordinator: coordinator,
        artifactStore: artifactStore,
        desktopRecoveryVerified: pending.desktopRecoveryVerified
      )
      controller?.showResult(pending.result, status: draftFailureStatus(error))
      NSSound.beep()
    }
  }

  private func undoDraft(
    _ pending: PendingUndo,
    coordinator: DesktopTaskCoordinator,
    artifactStore: PrivateArtifactStore
  ) async {
    do {
      try await coordinator.markRestoring(taskID: pending.taskID)
      controller?.setStatus("正在核对并恢复原内容…")
      let result = try await draftExecutor.undo(
        reference: pending.reference,
        taskID: pending.taskID
      )
      guard result.receipt.isVerifiedSuccess else {
        throw DraftMutationError.verificationFailed
      }
      try await coordinator.completeMutation(
        taskID: pending.taskID,
        succeeded: true,
        reason: "user invoked undo and the original field state was restored"
      )
      _ = await finishCleanup(
        taskID: pending.taskID,
        coordinator: coordinator,
        artifactStore: artifactStore,
        desktopRecoveryVerified: pending.desktopRecoveryVerified
      )
      controller?.showResult(pending.result, status: "已撤销 · 原内容已恢复")
    } catch {
      try? await coordinator.completeMutation(
        taskID: pending.taskID,
        succeeded: false,
        reason: "undo was refused because its compare-and-swap precondition changed"
      )
      _ = await finishCleanup(
        taskID: pending.taskID,
        coordinator: coordinator,
        artifactStore: artifactStore,
        desktopRecoveryVerified: pending.desktopRecoveryVerified
      )
      controller?.showResult(pending.result, status: undoFailureStatus(error))
      NSSound.beep()
    }
  }

  private func scheduleUndoFinalization(
    _ pending: PendingUndo,
    coordinator: DesktopTaskCoordinator,
    artifactStore: PrivateArtifactStore
  ) {
    undoFinalizer?.cancel()
    undoFinalizer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(30))
      guard !Task.isCancelled, let self,
        self.pendingUndo?.reference == pending.reference
      else { return }
      self.pendingUndo = nil
      await self.finalizeAcceptedDraft(
        pending,
        coordinator: coordinator,
        artifactStore: artifactStore,
        updateVisibleUI: true
      )
    }
  }

  private func finalizeAcceptedDraft(
    _ pending: PendingUndo,
    coordinator: DesktopTaskCoordinator,
    artifactStore: PrivateArtifactStore,
    updateVisibleUI: Bool
  ) async {
    await draftExecutor.discardUndo(reference: pending.reference)
    try? await coordinator.completeMutation(
      taskID: pending.taskID,
      succeeded: true,
      reason: "verified draft insertion was accepted after the bounded undo window"
    )
    _ = await finishCleanup(
      taskID: pending.taskID,
      coordinator: coordinator,
      artifactStore: artifactStore,
      desktopRecoveryVerified: pending.desktopRecoveryVerified
    )
    if updateVisibleUI {
      controller?.showResult(pending.result, status: "已插入 · 未发送")
    }
  }

  private func handleDismiss() {
    undoFinalizer?.cancel()
    undoFinalizer = nil
    if pendingLoginRequest != nil {
      pendingLoginRequest = nil
      task?.cancel()
      task = nil
      Task { await loginCoordinator?.cancel() }
      loginCoordinator = nil
      return
    }
    if let pendingDraft, let coordinator, let artifactStore {
      self.pendingDraft = nil
      task = Task {
        try? await coordinator.cancel(
          taskID: pendingDraft.taskID,
          reason: "user dismissed the generated draft without inserting it"
        )
        _ = await finishCleanup(
          taskID: pendingDraft.taskID,
          coordinator: coordinator,
          artifactStore: artifactStore,
          desktopRecoveryVerified: pendingDraft.desktopRecoveryVerified
        )
      }
      return
    }
    if let pendingUndo, let coordinator, let artifactStore {
      self.pendingUndo = nil
      task = Task {
        await finalizeAcceptedDraft(
          pendingUndo,
          coordinator: coordinator,
          artifactStore: artifactStore,
          updateVisibleUI: false
        )
      }
      return
    }
    task?.cancel()
  }

  private func finishPendingForTermination() async {
    undoFinalizer?.cancel()
    undoFinalizer = nil
    guard let coordinator, let artifactStore else { return }
    pendingLoginRequest = nil
    await loginCoordinator?.cancel()
    loginCoordinator = nil
    if let pendingDraft {
      self.pendingDraft = nil
      try? await coordinator.cancel(
        taskID: pendingDraft.taskID,
        reason: "host terminated while a generated draft awaited approval"
      )
      _ = await finishCleanup(
        taskID: pendingDraft.taskID,
        coordinator: coordinator,
        artifactStore: artifactStore,
        desktopRecoveryVerified: pendingDraft.desktopRecoveryVerified
      )
    }
    if let pendingUndo {
      self.pendingUndo = nil
      await finalizeAcceptedDraft(
        pendingUndo,
        coordinator: coordinator,
        artifactStore: artifactStore,
        updateVisibleUI: false
      )
    }
  }

  private func applicationSupportDirectory() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = base.appendingPathComponent("Mien", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    return directory
  }

  private func taskFailureReason(_ error: Error) -> String {
    if let connectionError = error as? ACPConnectionError,
      case .requestTimedOut(let method) = connectionError
    {
      return "ACP request deadline exceeded: \(method)"
    }
    if error as? CodexAgentBridgeError == .taskDeadlineExceeded {
      return "task deadline elapsed before the agent turn completed"
    }
    return "agent runtime failed"
  }

  private func taskFailureStatus(_ error: Error) -> String {
    if let connectionError = error as? ACPConnectionError,
      case .requestTimedOut = connectionError
    {
      return "Codex 响应超时，可重试"
    }
    if error as? CodexAgentBridgeError == .taskDeadlineExceeded {
      return "任务已超时，可重试"
    }
    return "Codex 未完成，可重试"
  }

  private func draftFailureReason(_ error: Error) -> String {
    switch error as? DraftMutationError {
    case .targetChanged, .stalePrecondition:
      "draft target changed before the approved compare-and-swap write"
    case .selectionUnavailable:
      "the nonempty field did not expose a safe caret or selection"
    case .protectedField:
      "the destination became protected before insertion"
    case .rollbackFailed:
      "draft verification and automatic rollback both failed"
    default:
      "reversible draft insertion failed"
    }
  }

  private func draftFailureStatus(_ error: Error) -> String {
    switch error as? DraftMutationError {
    case .targetChanged, .stalePrecondition:
      "原输入框已变化 · 未写入"
    case .selectionUnavailable:
      "无法确认光标位置 · 未覆盖原文"
    case .protectedField:
      "此输入框受保护 · 未写入"
    case .rollbackFailed:
      "写入验证失败 · 请检查原输入框"
    default:
      "未写入 · 草稿仍可复制"
    }
  }

  private func undoFailureStatus(_ error: Error) -> String {
    switch error as? DraftMutationError {
    case .undoPreconditionChanged:
      "输入框已有新修改 · 未覆盖"
    case .undoExpired:
      "撤销窗口已结束"
    default:
      "未能撤销 · 请检查原输入框"
    }
  }

  private func taskWorkingDirectory(taskID: UUID) throws -> URL {
    let directory = try applicationSupportDirectory()
      .appendingPathComponent("Tasks", isDirectory: true)
      .appendingPathComponent(taskID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    return directory
  }

  private func finishCleanup(
    taskID: UUID,
    coordinator: DesktopTaskCoordinator,
    artifactStore: PrivateArtifactStore,
    desktopRecoveryVerified: Bool = true
  ) async -> Bool {
    let localCleanupVerified = await cleanupEphemeralData(
      taskID: taskID,
      artifactStore: artifactStore
    )
    do {
      guard localCleanupVerified, desktopRecoveryVerified else { return false }
      try await coordinator.verifyCleanup(
        taskID: taskID,
        reason: "artifact and task workspace deletion verified"
      )
      return true
    } catch {
      return false
    }
  }

  private func cleanupEphemeralData(
    taskID: UUID,
    artifactStore: PrivateArtifactStore
  ) async -> Bool {
    do {
      _ = try await artifactStore.removeArtifacts(for: taskID)
      try removeTaskDirectory(taskID: taskID)
      return true
    } catch {
      return false
    }
  }

  private func presentTask(
    taskID: UUID,
    coordinator: DesktopTaskCoordinator,
    result: String? = nil,
    cleanupVerified: Bool? = nil,
    action: TaskPresentationAction? = nil
  ) async {
    guard let events = try? await coordinator.events(taskID: taskID),
      var presentation = TaskPresentationReducer().reduce(
        events: events,
        result: result,
        action: action
      )
    else {
      return
    }
    if cleanupVerified == false, presentation.result != nil {
      presentation = TaskPresentation(
        taskID: presentation.taskID,
        sequence: presentation.sequence,
        status: "结果已生成 · 清理待恢复",
        result: presentation.result,
        allowsRetry: false,
        action: presentation.action
      )
    }
    controller?.present(presentation)
  }

  private func removeTaskDirectory(taskID: UUID) throws {
    let directory = try applicationSupportDirectory()
      .appendingPathComponent("Tasks", isDirectory: true)
      .appendingPathComponent(taskID.uuidString, isDirectory: true)
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
    guard !FileManager.default.fileExists(atPath: directory.path) else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  private func recoverInterruptedTasks(
    journal: JSONLTaskEventJournal,
    supportURL: URL
  ) async throws {
    _ = try await journal.repairTrailingRecord()
    let plans = try TaskRecoveryAuditor.plans(for: await journal.replay())
    for plan in plans {
      try removeResidualDirectory(
        taskID: plan.taskID,
        rootURL: supportURL.appendingPathComponent("Tasks", isDirectory: true)
      )
      try removeResidualDirectory(
        taskID: plan.taskID,
        rootURL: supportURL.appendingPathComponent("Artifacts", isDirectory: true)
      )
      let events = TaskRecoveryAuditor.recoveryEvents(
        for: plan,
        localResidueRemoved: true
      )
      try await journal.append(events)
    }
  }

  private func removeResidualDirectory(taskID: UUID, rootURL: URL) throws {
    let root = rootURL.standardizedFileURL
    let directory = root.appendingPathComponent(taskID.uuidString, isDirectory: true)
      .standardizedFileURL
    guard directory.deletingLastPathComponent() == root else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
    guard !FileManager.default.fileExists(atPath: directory.path) else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  private func makeAgentBridge(applicationSupportURL: URL) -> CodexAgentBridge? {
    let helperDirectory = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers", isDirectory: true)
    let acpOverride = developerOverride(named: "CONTEXTUAL_ACTION_ACP_PATH")
    let codexOverride = developerOverride(named: "CONTEXTUAL_ACTION_CODEX_PATH")
    let acpURL = acpOverride ?? helperDirectory.appendingPathComponent("codex-acp")
    let codexURL = codexOverride ?? helperDirectory.appendingPathComponent("codex")
    guard FileManager.default.isExecutableFile(atPath: acpURL.path),
      FileManager.default.isExecutableFile(atPath: codexURL.path)
    else {
      return nil
    }
    let bundled = acpOverride == nil && codexOverride == nil
    let digests = bundled ? runtimeDigests() : nil
    if bundled {
      guard let digests,
        (try? ExecutableIntegrity.verify(
          acpURL,
          expectedSHA256: digests.codexACP,
          requireValidCodeSignature: true
        )) != nil,
        (try? ExecutableIntegrity.verify(
          codexURL,
          expectedSHA256: digests.codex,
          requireValidCodeSignature: true
        )) != nil
      else {
        return nil
      }
    }
    let codexHome: URL
    if let override = developerOverride(named: "CONTEXTUAL_ACTION_CODEX_HOME") {
      codexHome = override
    } else {
      codexHome =
        applicationSupportURL
        .appendingPathComponent("AgentRuntime", isDirectory: true)
        .appendingPathComponent("CodexHome", isDirectory: true)
      guard
        (try? FileManager.default.createDirectory(
          at: codexHome,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )) != nil
      else {
        return nil
      }
      do {
        let result = try CodexCredentialBootstrap().prepare(
          sourceHome: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true),
          destinationHome: codexHome
        )
        if result == .sourceUnavailable {
          agentUnavailableStatus = "需要先登录 Codex"
          return nil
        }
      } catch {
        agentUnavailableStatus = "Codex 登录信息不可用"
        return nil
      }
    }
    let taskRoot = applicationSupportURL.appendingPathComponent("Tasks", isDirectory: true)
    let process = ACPProcessConfiguration(
      executableURL: acpURL,
      workingDirectoryURL: taskRoot,
      environment: [
        "PATH": "\(helperDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin",
        "CODEX_PATH": codexURL.path,
        "CODEX_HOME": codexHome.path,
        "CODEX_CONFIG":
          #"{"approval_policy":"never","mcp_servers":{},"sandbox_mode":"read-only"}"#,
        "NO_BROWSER": "1",
        "INITIAL_AGENT_MODE": "read-only",
      ],
      expectedExecutableSHA256: digests?.codexACP
    )
    guard
      let configuration = try? CodexAgentBridgeConfiguration(
        process: process,
        clientInfo: ACPImplementation(
          name: "mien",
          title: "Mien",
          version: "0.1.0"
        )
      )
    else {
      return nil
    }
    return CodexAgentBridge(configuration: configuration)
  }

  private func makeLoginCoordinator() throws -> CodexDeviceLoginCoordinator? {
    let supportURL = try applicationSupportDirectory()
    let helperDirectory = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers", isDirectory: true)
    let codexOverride = developerOverride(named: "CONTEXTUAL_ACTION_CODEX_PATH")
    let codexURL = codexOverride ?? helperDirectory.appendingPathComponent("codex")
    guard FileManager.default.isExecutableFile(atPath: codexURL.path) else { return nil }
    if codexOverride == nil {
      guard let digest = runtimeDigests()?.codex,
        (try? ExecutableIntegrity.verify(
          codexURL,
          expectedSHA256: digest,
          requireValidCodeSignature: true
        )) != nil
      else { return nil }
    }
    let codexHome =
      supportURL
      .appendingPathComponent("AgentRuntime", isDirectory: true)
      .appendingPathComponent("CodexHome", isDirectory: true)
    let taskRoot = supportURL.appendingPathComponent("Tasks", isDirectory: true)
    try FileManager.default.createDirectory(
      at: taskRoot,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let configuration = try CodexDeviceLoginConfiguration(
      executableURL: codexURL,
      codexHomeURL: codexHome,
      workingDirectoryURL: taskRoot,
      environment: [
        "PATH": "\(helperDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": NSTemporaryDirectory(),
        "LANG": "en_US.UTF-8",
      ]
    )
    return CodexDeviceLoginCoordinator(configuration: configuration)
  }

  private func makeLongviewProvider(
    applicationSupportURL: URL,
    store: PrivateArtifactStore
  ) -> LongviewContextProvider? {
    let helperDirectory = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers", isDirectory: true)
    let override = developerOverride(named: "CONTEXTUAL_ACTION_LONGVIEW_PATH")
    let executableURL =
      override
      ?? helperDirectory.appendingPathComponent("longview")
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
      return nil
    }
    if override == nil {
      guard let digest = runtimeDigests()?.longview,
        (try? ExecutableIntegrity.verify(
          executableURL,
          expectedSHA256: digest,
          requireValidCodeSignature: true
        )) != nil
      else {
        return nil
      }
    }
    let temporaryRoot =
      applicationSupportURL
      .appendingPathComponent("Temporary", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: temporaryRoot,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    return try? LongviewContextProvider(
      executableURL: executableURL,
      store: store,
      temporaryRoot: temporaryRoot
    )
  }

  private func developerOverride(named name: String) -> URL? {
    #if DEBUG
      return ProcessInfo.processInfo.environment[name].map(URL.init(fileURLWithPath:))
    #else
      return nil
    #endif
  }

  private func runtimeDigests() -> RuntimeDigests? {
    guard
      let url = Bundle.main.url(
        forResource: "runtime-digests",
        withExtension: "json"
      ), let data = try? Data(contentsOf: url)
    else {
      return nil
    }
    return try? JSONDecoder().decode(RuntimeDigests.self, from: data)
  }
}

@main
@MainActor
private enum MienMain {
  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
  }
}
