import ACPGateway
import ActionKernel
import AppKit
import ArtifactStore
import ContextKernel
import DesktopActionAdapters
import HostRuntime
import InteractionShell
import MienContracts
import OSLog
import PermissionKernel
import PolicyKernel
import ProviderAdapters
import TaskRuntime

private struct ResolvedAgentTurnContext: Sendable {
  let decision: AgentContextDecision
  let capsule: TaskCapsule
  let targetLease: TargetLease
  let mutationTarget: AXElementFingerprint?
  let sensitivity: Sensitivity
  let desktopRecoveryVerified: Bool
}

private struct FulfilledAgentContextTool: Sendable {
  let context: ResolvedAgentTurnContext
  let blocks: [ACPContentBlock]
}

private enum AgentContextToolError: Error, Sendable {
  case protectedContent
  case accessibilityPermissionUnavailable
  case pixelEvidenceUnavailable
  case screenRecordingPermissionUnavailable
  case transmissionDenied
}

private actor AgentTurnContextState {
  private var value: ResolvedAgentTurnContext?

  func store(_ value: ResolvedAgentTurnContext) {
    precondition(self.value == nil, "one Host task may resolve context only once")
    self.value = value
  }

  func load() -> ResolvedAgentTurnContext? { value }
}

@MainActor
final class MienConversationController {
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

  private weak var controller: InteractionController?
  private let coordinator: DesktopTaskCoordinator
  private let artifactStore: PrivateArtifactStore
  private var agentBridge: PiAgentBridge?
  private let longviewProvider: LongviewContextProvider?
  private let supportURL: URL
  private let modelPreferenceStore: AgentModelPreferenceStore
  private let work = ConversationWorkQueue()
  private var conversationID: UUID?
  private var pendingDraft: PendingDraft?
  private var pendingUndo: PendingUndo?
  private var undoFinalizer: Task<Void, Never>?
  private var awaitsAuthentication = false
  private let draftExecutor = AXDraftExecutor()
  private lazy var actionBroker = ActionBroker(executors: [draftExecutor])
  private let logger = Logger(subsystem: "io.github.kohoj.mien", category: "conversation")
  var onConnectAgent: (() -> Void)?

  init(
    runtime: PreparedMienRuntime, controller: InteractionController,
    preferences: AgentModelPreferenceStore
  ) {
    self.controller = controller
    coordinator = runtime.coordinator
    artifactStore = runtime.artifactStore
    agentBridge = runtime.agentBridge
    longviewProvider = runtime.longviewProvider
    supportURL = runtime.supportURL
    modelPreferenceStore = preferences
  }

  func submit(intent: String, snapshot: InvocationSnapshot) {
    guard let agentBridge else {
      awaitsAuthentication = true
      controller?.showActionPrompt(status: "连接 Codex 后继续", action: .loginCodex)
      controller?.showPermissionOnboarding()
      return
    }
    let conversationID = self.conversationID ?? UUID()
    self.conversationID = conversationID
    work.submit { [weak self] in
      guard let self, !Task.isCancelled else { return }
      self.controller?.setStatus("Agent 正在判断需要看什么…")
      await self.runTask(
        intent: intent,
        snapshot: snapshot,
        conversationID: conversationID,
        coordinator: coordinator,
        artifactStore: artifactStore,
        agentBridge: agentBridge
      )
    }
  }

  private func runTask(
    intent: String,
    snapshot: InvocationSnapshot,
    conversationID: UUID,
    coordinator: DesktopTaskCoordinator,
    artifactStore: PrivateArtifactStore,
    agentBridge: PiAgentBridge
  ) async {
    var taskID: UUID?
    var taskWasLocked = false
    var agentStarted = false
    var desktopRecoveryVerified = true
    var contextState: AgentTurnContextState?
    var activityTask: Task<Void, Never>?
    defer { activityTask?.cancel() }
    do {
      let newTaskID = UUID()
      taskID = newTaskID
      let workingDirectory = try conversationWorkingDirectory(
        conversationID: conversationID
      )
      let sessionID = try await agentBridge.openConversationTaskSession(
        taskID: newTaskID,
        conversationID: conversationID,
        workingDirectory: workingDirectory,
        preferredModelID: modelPreferenceStore.modelID
      )
      let activityUpdates = try await agentBridge.activityUpdates(taskID: newTaskID)
      activityTask = Task { @MainActor [weak self] in
        guard let self else { return }
        for await update in activityUpdates {
          guard !Task.isCancelled else { return }
          self.controller?.presentAgentActivity(self.agentActivityPresentation(update))
        }
      }
      let locked = try await coordinator.lockTarget(
        intent: intent,
        snapshot: snapshot,
        taskID: newTaskID,
        acpSessionID: sessionID,
        allowedActions: [.read, .proposeDraft, .reversibleWrite]
      )
      taskWasLocked = true
      controller?.bind(taskID: locked.capsule.id)
      try await coordinator.markContextPlanning(taskID: locked.capsule.id)
      await presentTask(taskID: locked.capsule.id, coordinator: coordinator)

      let permissionCoordinator = DesktopPermissionCoordinator()
      let capabilities = agentEvidenceCapabilities(
        snapshot: snapshot,
        target: locked.targetLease,
        permissionCoordinator: permissionCoordinator
      )
      let turnContextState = AgentTurnContextState()
      contextState = turnContextState
      let result = try await agentBridge.runTurn(
        taskID: locked.capsule.id,
        userInput: intent,
        target: locked.targetLease,
        capabilities: capabilities,
        deadline: locked.capsule.deadline,
        contextHandler: { [weak self] decision in
          guard let self else { throw CancellationError() }
          let fulfilled = try await self.fulfillAgentContextDecision(
            decision: decision,
            snapshot: snapshot,
            locked: locked,
            coordinator: coordinator,
            artifactStore: artifactStore
          )
          await turnContextState.store(fulfilled.context)
          return fulfilled.blocks
        }
      )
      guard let resolved = await turnContextState.load(),
        resolved.decision == result.contextDecision
      else {
        throw PiAgentBridgeError.invalidAgentProtocol
      }
      let sensitivity = resolved.sensitivity
      desktopRecoveryVerified = resolved.desktopRecoveryVerified
      agentStarted = true
      try Task.checkCancellation()
      if result.outcome.kind == .draftProposal, let mutationTarget = resolved.mutationTarget {
        try await coordinator.markAwaitingPermission(taskID: resolved.capsule.id)
        _ = await cleanupEphemeralData(
          taskID: resolved.capsule.id,
          artifactStore: artifactStore
        )
        pendingDraft = PendingDraft(
          taskID: resolved.capsule.id,
          window: resolved.targetLease.window,
          element: mutationTarget,
          result: result.outcome.content,
          sensitivity: sensitivity,
          desktopRecoveryVerified: desktopRecoveryVerified
        )
        await presentTask(
          taskID: resolved.capsule.id,
          coordinator: coordinator,
          result: result.outcome.content,
          action: .insertDraft
        )
        return
      }
      try await coordinator.completeReadOnly(
        taskID: resolved.capsule.id,
        succeeded: true,
        reason: "Host received and validated a typed Agent outcome"
      )
      let cleanupVerified = await finishCleanup(
        taskID: resolved.capsule.id,
        coordinator: coordinator,
        artifactStore: artifactStore,
        desktopRecoveryVerified: desktopRecoveryVerified
      )
      await presentTask(
        taskID: resolved.capsule.id,
        coordinator: coordinator,
        result: result.outcome.content,
        cleanupVerified: cleanupVerified
      )
    } catch is CancellationError {
      if let taskID {
        await agentBridge.invalidateConversation(containingTaskID: taskID)
        if taskWasLocked {
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
      }
    } catch {
      if let contextState, await contextState.load() != nil {
        agentStarted = true
      }
      if let taskID {
        // Host-side failures after a completed ACP request end this fresh task
        // without silently discarding the conversation. If ACP already
        // invalidated the session, this is an observable no-op.
        try? await agentBridge.releaseTaskBindingPreservingConversation(taskID: taskID)
        if taskWasLocked {
          if agentStarted {
            try? await coordinator.completeReadOnly(
              taskID: taskID,
              succeeded: false,
              reason: taskFailureReason(error)
            )
          } else {
            try? await coordinator.fail(taskID: taskID, reason: taskFailureReason(error))
          }
          _ = await finishCleanup(
            taskID: taskID,
            coordinator: coordinator,
            artifactStore: artifactStore,
            desktopRecoveryVerified: desktopRecoveryVerified
          )
          if await agentBridge.conversationIsValid(conversationID: conversationID) {
            await presentTask(taskID: taskID, coordinator: coordinator)
          } else {
            invalidateVisibleConversation(
              conversationID: conversationID,
              status: "Agent 会话已中断 · 请重新唤起 Mien"
            )
          }
        }
      }
      // Once a task is ledger-backed, its terminal reason is the authoritative
      // user-facing failure. `presentTask` has already projected that reason;
      // replacing it with a generic runtime error would misattribute context
      // acquisition failures to Codex.
      if !taskWasLocked {
        if case .preferredModelUnavailable = error as? PiAgentBridgeError {
          controller?.beginLoadingAgentModels()
          do {
            controller?.setAgentModelCatalog(try await agentBridge.discoverModels())
          } catch {
            controller?.setAgentModelLoadingFailed()
            logger.error(
              "model catalog refresh failed error=\(String(describing: error), privacy: .public)"
            )
          }
        }
        if error as? PiAgentBridgeError != .authenticationRequired {
          if await agentBridge.conversationIsValid(conversationID: conversationID) {
            controller?.setStatus(taskFailureStatus(error), allowsRetry: true)
          } else {
            invalidateVisibleConversation(
              conversationID: conversationID,
              status: "Agent 会话已中断 · 请重新唤起 Mien"
            )
          }
        }
      }
      if error as? PiAgentBridgeError == .authenticationRequired {
        awaitsAuthentication = true
        controller?.setAgentReadiness(.authenticationRequired)
        if !taskWasLocked {
          controller?.showActionPrompt(
            status: "Codex 认证失败 · 请重新连接",
            action: .loginCodex
          )
        }
        logger.error(
          "agent authentication required taskID=\(taskID?.uuidString ?? "unbound", privacy: .public)"
        )
      }
      NSSound.beep()
    }
  }

  private func fulfillAgentContextDecision(
    decision: AgentContextDecision,
    snapshot: InvocationSnapshot,
    locked: LockedDesktopTask,
    coordinator: DesktopTaskCoordinator,
    artifactStore: PrivateArtifactStore
  ) async throws -> FulfilledAgentContextTool {
    switch decision.kind {
    case .none:
      guard decision.request == nil else {
        throw PiAgentBridgeError.agentProtocolViolation(.malformedContextDecision)
      }
      let sensitivity = SurfaceSensitivityClassifier().classify(
        bundleIdentifier: locked.targetLease.window.bundleIdentifier,
        semanticTarget: locked.targetLease.semanticTarget
      )
      try await coordinator.markAgentRunningWithoutContext(taskID: locked.capsule.id)
      controller?.allowBackgroundCompletion()
      controller?.setStatus("Agent 正在处理…")
      await presentTask(taskID: locked.capsule.id, coordinator: coordinator)
      return FulfilledAgentContextTool(
        context: ResolvedAgentTurnContext(
          decision: decision,
          capsule: locked.capsule,
          targetLease: locked.targetLease,
          mutationTarget: locked.mutationTarget,
          sensitivity: sensitivity,
          desktopRecoveryVerified: true
        ),
        blocks: [
          .text("Host confirmed: this turn acquired and transmitted no external evidence.")
        ]
      )
    case .request:
      guard let request = decision.request else {
        throw PiAgentBridgeError.agentProtocolViolation(.malformedContextDecision)
      }
      return try await fulfillAgentContextTool(
        decision: decision,
        request: request,
        snapshot: snapshot,
        locked: locked,
        coordinator: coordinator,
        artifactStore: artifactStore
      )
    }
  }

  private func fulfillAgentContextTool(
    decision: AgentContextDecision,
    request: AgentContextRequest,
    snapshot: InvocationSnapshot,
    locked: LockedDesktopTask,
    coordinator: DesktopTaskCoordinator,
    artifactStore: PrivateArtifactStore
  ) async throws -> FulfilledAgentContextTool {
    let prepared = try await coordinator.prepareContext(
      taskID: locked.capsule.id,
      request: request
    )
    let requestedEvidence = Set(request.evidence)
    let subject = PolicySubject(
      bundleIdentifier: prepared.targetLease.window.bundleIdentifier,
      windowID: prepared.targetLease.window.windowID,
      scope: request.scope,
      protectedContent: prepared.targetLease.semanticTarget?.protectedContent == true
    )
    let preflightSensitivity = SurfaceSensitivityClassifier().classify(
      bundleIdentifier: subject.bundleIdentifier,
      semanticTarget: prepared.targetLease.semanticTarget
    )
    let permissionCoordinator = DesktopPermissionCoordinator()
    var providers: [any ContextProvider] = []
    if requestedEvidence.contains(.selectedText) {
      providers.append(SelectionContextProvider(snapshot: snapshot, store: artifactStore))
    }
    if requestedEvidence.contains(.accessibility) {
      guard
        case .allow = PolicyEngine().evaluate(
          PolicyRequest(
            taskID: prepared.capsule.id,
            subject: subject,
            operation: .readAccessibility,
            sensitivity: preflightSensitivity,
            destination: .hostOnly,
            userInitiated: true
          ))
      else {
        throw AgentContextToolError.protectedContent
      }
      var status = permissionCoordinator.status(for: .accessibility)
      if status != .authorized { status = permissionCoordinator.request(.accessibility) }
      guard status == .authorized else {
        controller?.showPermissionOnboarding(focusing: .accessibility)
        throw AgentContextToolError.accessibilityPermissionUnavailable
      }
      providers.append(AccessibilityContextProvider(store: artifactStore))
    }
    let needsPixels =
      requestedEvidence.contains(.currentFrame)
      || requestedEvidence.contains(.visualHistory)
    var desktopRecoveryVerified = true
    if needsPixels {
      guard
        case .allow = PolicyEngine().evaluate(
          PolicyRequest(
            taskID: prepared.capsule.id,
            subject: subject,
            operation: .capturePixels,
            sensitivity: preflightSensitivity,
            destination: .hostOnly,
            userInitiated: true
          )), let longviewProvider
      else {
        throw AgentContextToolError.pixelEvidenceUnavailable
      }
      var status = permissionCoordinator.status(for: .screenRecording)
      if status != .authorized { status = permissionCoordinator.request(.screenRecording) }
      guard status == .authorized else {
        controller?.showPermissionOnboarding(focusing: .screenRecording)
        throw AgentContextToolError.screenRecordingPermissionUnavailable
      }
      providers.append(longviewProvider)
      desktopRecoveryVerified = false
    }
    controller?.setStatus(
      requestedEvidence.contains(.visualHistory)
        ? "正在读取更多画面…"
        : (needsPixels ? "正在理解当前画面…" : "正在读取界面…")
    )
    let resolution = try await ContextBroker(providers: providers).resolve(
      prepared.contextRequest
    )
    if resolution.artifacts.contains(where: { $0.provider == .longview }) {
      desktopRecoveryVerified = resolution.receipts.contains {
        $0.executor == "LongviewAdapter" && $0.recovery.isClean
      }
    }
    let sensitivity = max(
      preflightSensitivity,
      resolution.artifacts.map(\.sensitivity).max() ?? .publicData
    )
    let remoteTransmissionAllowed: Bool = {
      if case .allow = PolicyEngine().evaluate(
        PolicyRequest(
          taskID: prepared.capsule.id,
          subject: subject,
          operation: .transmit,
          sensitivity: sensitivity,
          destination: .codex,
          userInitiated: true
        ))
      {
        return true
      }
      return false
    }()
    let manifest = try await coordinator.attachContext(
      resolution,
      to: prepared.capsule.id,
      remoteTransmissionAllowed: remoteTransmissionAllowed,
      desktopRecoveryVerified: desktopRecoveryVerified
    )
    controller?.disclose(manifest)
    guard remoteTransmissionAllowed else {
      throw AgentContextToolError.transmissionDenied
    }
    try Task.checkCancellation()
    controller?.allowBackgroundCompletion()
    controller?.setStatus("Agent 正在处理…")
    try await coordinator.markAgentRunning(taskID: prepared.capsule.id)
    await presentTask(taskID: prepared.capsule.id, coordinator: coordinator)
    let blocks = try await AgentContextPayloadBuilder.build(
      capsule: prepared.capsule,
      manifest: manifest,
      artifactReader: artifactStore
    )
    return FulfilledAgentContextTool(
      context: ResolvedAgentTurnContext(
        decision: decision,
        capsule: prepared.capsule,
        targetLease: prepared.targetLease,
        mutationTarget: prepared.mutationTarget,
        sensitivity: sensitivity,
        desktopRecoveryVerified: desktopRecoveryVerified
      ),
      blocks: blocks
    )
  }

  private func agentEvidenceCapabilities(
    snapshot: InvocationSnapshot,
    target: TargetLease,
    permissionCoordinator: DesktopPermissionCoordinator
  ) -> [AgentEvidenceCapability] {
    var capabilities: [AgentEvidenceCapability] = []
    if snapshot.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
      capabilities.append(
        AgentEvidenceCapability(kind: .selectedText, availability: .available)
      )
    }
    if target.semanticTarget?.frame != nil, target.semanticTarget?.protectedContent != true {
      capabilities.append(
        AgentEvidenceCapability(
          kind: .accessibility,
          availability: permissionCoordinator.status(for: .accessibility) == .authorized
            ? .available : .requiresAuthorization
        )
      )
    }
    if longviewProvider != nil {
      let availability: AgentEvidenceAvailability =
        permissionCoordinator.status(for: .screenRecording) == .authorized
        ? .available : .requiresAuthorization
      capabilities.append(
        AgentEvidenceCapability(kind: .currentFrame, availability: availability)
      )
      capabilities.append(
        AgentEvidenceCapability(kind: .visualHistory, availability: availability)
      )
    }
    return capabilities
  }

  private func failContextPreparation(
    taskID: UUID,
    reason: String,
    status: String,
    focusing permission: DesktopPermission? = nil,
    coordinator: DesktopTaskCoordinator,
    artifactStore: PrivateArtifactStore,
    agentBridge: PiAgentBridge
  ) async throws {
    try await coordinator.fail(taskID: taskID, reason: reason)
    do {
      try await agentBridge.releaseTaskBindingPreservingConversation(taskID: taskID)
    } catch {
      await agentBridge.invalidateConversation(containingTaskID: taskID)
      throw error
    }
    _ = await finishCleanup(
      taskID: taskID,
      coordinator: coordinator,
      artifactStore: artifactStore
    )
    controller?.setStatus(status, allowsRetry: true)
    if let permission { controller?.showPermissionOnboarding(focusing: permission) }
  }

  func handleResultAction(_ action: TaskPresentationAction) {
    switch action {
    case .insertDraft:
      guard let pendingDraft else { return }
      self.pendingDraft = nil
      work.continueWith { [weak self] in
        guard !Task.isCancelled else { return }
        guard let self else { return }
        await self.insertDraft(
          pendingDraft,
          coordinator: coordinator,
          artifactStore: artifactStore
        )
      }
    case .undoDraft:
      guard let pendingUndo else { return }
      self.pendingUndo = nil
      undoFinalizer?.cancel()
      undoFinalizer = nil
      work.continueWith { [weak self] in
        guard !Task.isCancelled else { return }
        guard let self else { return }
        await self.undoDraft(
          pendingUndo,
          coordinator: coordinator,
          artifactStore: artifactStore
        )
      }
    case .loginCodex:
      onConnectAgent?()
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
      try Task.checkCancellation()
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
      try Task.checkCancellation()
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
        guard !Task.isCancelled else { return }
        controller?.showResult(
          pending.result,
          status: "未能验证写入",
          outcome: .warning
        )
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
      guard !Task.isCancelled else { return }
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
      guard !Task.isCancelled else { return }
      controller?.showResult(
        pending.result,
        status: draftFailureStatus(error),
        outcome: .warning
      )
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
      guard !Task.isCancelled else { return }
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
      guard !Task.isCancelled else { return }
      controller?.showResult(
        pending.result,
        status: undoFailureStatus(error),
        outcome: .warning
      )
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
      // The timer only schedules work. Ledger/undo cleanup belongs to the same
      // serial owner as insertion, dismissal and termination.
      self.work.continueWith { [weak self] in
        guard let self, !Task.isCancelled,
          self.pendingUndo?.reference == pending.reference
        else { return }
        self.pendingUndo = nil
        await self.finalizeAcceptedDraft(
          pending, coordinator: coordinator, artifactStore: artifactStore,
          updateVisibleUI: true)
      }
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
    if updateVisibleUI, !Task.isCancelled {
      controller?.showResult(pending.result, status: "已插入 · 未发送")
    }
  }

  func dismiss() {
    awaitsAuthentication = false
    let closingID = conversationID
    conversationID = nil
    undoFinalizer?.cancel()
    undoFinalizer = nil
    // Retain and await teardown. A subsequent invocation queues behind this work.
    work.cleanup { [self] in
      await finishPendingForTermination()
      if let closingID {
        await agentBridge?.closeConversation(conversationID: closingID)
        do { try removeConversationDirectory(conversationID: closingID) } catch {
          logger.error(
            "conversation_cleanup_failed id=\(closingID.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)"
          )
        }
      }
    }
  }

  func waitForIdle() async { await work.waitForIdle() }

  func resumeAfterAuthentication(using bridge: PiAgentBridge) {
    agentBridge = bridge
    let shouldResume = awaitsAuthentication
    awaitsAuthentication = false
    if shouldResume { controller?.resumeAfterAuthentication() }
  }

  /// An ACP-invalidated session cannot truthfully back the transcript's next
  /// turn. Keep the failed turn visible, but require a fresh invocation instead
  /// of silently attaching the composer to a new Agent conversation.
  private func invalidateVisibleConversation(conversationID: UUID, status: String) {
    guard self.conversationID == conversationID else { return }
    self.conversationID = nil
    do {
      try removeConversationDirectory(conversationID: conversationID)
    } catch {
      logger.error(
        "invalidated conversation workspace cleanup failed conversationID=\(conversationID.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)"
      )
    }
    controller?.invalidateConversation(status: status)
  }

  private func finishPendingForTermination() async {
    undoFinalizer?.cancel()
    undoFinalizer = nil
    awaitsAuthentication = false
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

  private func taskFailureReason(_ error: Error) -> String {
    switch error as? AgentContextToolError {
    case .protectedContent:
      return "context policy denied the protected target"
    case .accessibilityPermissionUnavailable:
      return "accessibility permission unavailable for Agent-requested evidence"
    case .pixelEvidenceUnavailable:
      return "pixel evidence requested by Agent but unavailable"
    case .screenRecordingPermissionUnavailable:
      return "screen recording permission unavailable for Agent-requested evidence"
    case .transmissionDenied:
      return "policy kept context inside the local trust boundary"
    default:
      break
    }
    if let connectionError = error as? ACPConnectionError,
      case .requestTimedOut(let method) = connectionError
    {
      return "ACP request deadline exceeded: \(method)"
    }
    switch error as? PiAgentBridgeError {
    case .authenticationRequired:
      return "agent authentication required"
    case .modelCatalogUnavailable:
      return "agent model catalog unavailable"
    case .taskDeadlineExceeded:
      return "task deadline elapsed before the agent turn completed"
    case .invalidAgentProtocol:
      return "agent returned an invalid structured protocol envelope"
    case .agentProtocolViolation(let violation):
      return "agent protocol violation: \(violation.rawValue)"
    case .unavailableEvidenceRequested:
      return "agent requested evidence outside the advertised capability catalog"
    case .unsupportedContextRequest:
      return "agent selected a context request outside the advertised typed catalog"
    case .taskSessionUnavailable, .taskSessionAlreadyOpen:
      return "agent task session unavailable"
    case .unexpectedAgentStopReason:
      return "agent turn ended before a typed result"
    case .preferredModelUnavailable(let modelID):
      return "preferred agent model is unavailable: \(modelID)"
    case .invalidModelPreference:
      return "stored agent model preference is invalid"
    case .sessionCleanupFailed:
      return "agent session cleanup failed after model configuration"
    default:
      break
    }
    return "agent runtime failed"
  }

  private func taskFailureStatus(_ error: Error) -> String {
    switch error as? AgentContextToolError {
    case .protectedContent:
      return "此内容受保护"
    case .accessibilityPermissionUnavailable:
      return "需要允许读取界面"
    case .pixelEvidenceUnavailable:
      return "当前无法理解画面"
    case .screenRecordingPermissionUnavailable:
      return "需要允许理解画面"
    case .transmissionDenied:
      return "此内容不会发送给 Agent"
    default:
      break
    }
    if let connectionError = error as? ACPConnectionError,
      case .requestTimedOut = connectionError
    {
      return "Agent 响应超时，可重试"
    }
    switch error as? PiAgentBridgeError {
    case .authenticationRequired:
      return "Codex 认证失败 · 请重新连接"
    case .modelCatalogUnavailable:
      return "模型列表读取失败 · 可重试"
    case .taskDeadlineExceeded:
      return "任务已超时，可重试"
    case .invalidAgentProtocol, .agentProtocolViolation, .unavailableEvidenceRequested,
      .unsupportedContextRequest, .unexpectedAgentStopReason:
      return "Agent 没有完成判断，可重试"
    case .taskSessionUnavailable, .taskSessionAlreadyOpen:
      return "Agent 连接已中断，可重试"
    case .preferredModelUnavailable, .invalidModelPreference:
      return "所选模型不可用 · 请在 Mien 设置中更换"
    case .sessionCleanupFailed:
      return "Agent 会话未能安全关闭，可重试"
    default:
      break
    }
    return "Agent 未完成，可重试"
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

  private func conversationWorkingDirectory(conversationID: UUID) throws -> URL {
    let directory =
      supportURL
      .appendingPathComponent("Conversations", isDirectory: true)
      .appendingPathComponent(conversationID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    return directory
  }

  private func removeConversationDirectory(conversationID: UUID) throws {
    let root =
      supportURL
      .appendingPathComponent("Conversations", isDirectory: true)
      .standardizedFileURL
    let directory = root.appendingPathComponent(conversationID.uuidString, isDirectory: true)
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

  private func agentActivityPresentation(
    _ update: ACPAgentActivityUpdate
  ) -> AgentActivityPresentation {
    let kind: AgentActivityPresentation.Kind =
      switch update.kind {
      case .thinking: .thinking
      case .tool: .tool
      case .plan: .plan
      }
    let status: AgentActivityPresentation.Status =
      switch update.status {
      case .active: .active
      case .completed: .completed
      case .failed: .failed
      }
    return AgentActivityPresentation(
      id: update.id,
      kind: kind,
      toolName: update.toolName,
      status: status
    )
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
        action: presentation.action,
        outcome: .warning
      )
    }
    guard !Task.isCancelled else { return }
    controller?.present(presentation)
  }

  private func removeTaskDirectory(taskID: UUID) throws {
    let directory =
      supportURL
      .appendingPathComponent("Tasks", isDirectory: true)
      .appendingPathComponent(taskID.uuidString, isDirectory: true)
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
    guard !FileManager.default.fileExists(atPath: directory.path) else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

}
