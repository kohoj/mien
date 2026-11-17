import ContextKernel
import CryptoKit
import Foundation
import MienContracts
import TaskRuntime

public struct DesktopTaskConfiguration: Equatable, Sendable {
  public let targetLeaseDuration: TimeInterval
  public let contextPlanningDeadline: TimeInterval
  public let contextDeadline: TimeInterval
  public let boundedHistoryContextDeadline: TimeInterval
  public let taskDeadline: TimeInterval
  public let maximumArtifacts: Int
  public let maximumBytes: Int
  public let maximumTextCharacters: Int

  public init(
    targetLeaseDuration: TimeInterval = 45,
    contextPlanningDeadline: TimeInterval = 20,
    contextDeadline: TimeInterval = 3,
    boundedHistoryContextDeadline: TimeInterval = 18,
    taskDeadline: TimeInterval = 90,
    maximumArtifacts: Int = 8,
    maximumBytes: Int = 24 * 1_024 * 1_024,
    maximumTextCharacters: Int = 120_000
  ) {
    self.targetLeaseDuration = targetLeaseDuration
    self.contextPlanningDeadline = contextPlanningDeadline
    self.contextDeadline = contextDeadline
    self.boundedHistoryContextDeadline = boundedHistoryContextDeadline
    self.taskDeadline = taskDeadline
    self.maximumArtifacts = maximumArtifacts
    self.maximumBytes = maximumBytes
    self.maximumTextCharacters = maximumTextCharacters
  }
}

public struct PreparedDesktopTask: Sendable {
  public let capsule: TaskCapsule
  public let targetLease: TargetLease
  public let mutationTarget: AXElementFingerprint?
  public let contextRequest: ContextCaptureRequest

  public init(
    capsule: TaskCapsule,
    targetLease: TargetLease,
    mutationTarget: AXElementFingerprint?,
    contextRequest: ContextCaptureRequest
  ) {
    self.capsule = capsule
    self.targetLease = targetLease
    self.mutationTarget = mutationTarget
    self.contextRequest = contextRequest
  }
}

public struct LockedDesktopTask: Sendable {
  public let capsule: TaskCapsule
  public let targetLease: TargetLease
  public let mutationTarget: AXElementFingerprint?

  public init(
    capsule: TaskCapsule,
    targetLease: TargetLease,
    mutationTarget: AXElementFingerprint?
  ) {
    self.capsule = capsule
    self.targetLease = targetLease
    self.mutationTarget = mutationTarget
  }
}

public enum DesktopTaskCoordinatorError: Error, Equatable, Sendable {
  case emptyIntent
  case invalidConfiguration
  case invalidSnapshot
  case taskNotFound
  case manifestAlreadyAttached
  case noUsableContext
}

public actor DesktopTaskCoordinator {
  private struct ActiveTask {
    let locked: LockedDesktopTask
    let ledger: TaskLedger
    var contextRequest: ContextCaptureRequest?
    var manifest: ContextManifest?
  }

  private let configuration: DesktopTaskConfiguration
  private let journal: (any TaskEventJournaling)?
  private var tasks: [UUID: ActiveTask] = [:]
  private var archivedEvents: [UUID: [TaskEvent]] = [:]
  private var archiveOrder: [UUID] = []

  public init(
    configuration: DesktopTaskConfiguration = DesktopTaskConfiguration(),
    journal: (any TaskEventJournaling)? = nil
  ) throws {
    guard configuration.targetLeaseDuration > 0,
      configuration.contextPlanningDeadline > 0,
      configuration.contextDeadline > 0,
      configuration.boundedHistoryContextDeadline >= configuration.contextDeadline,
      // The immutable target must survive both Agent planning and the slowest
      // evidence route it can select.
      configuration.targetLeaseDuration
        >= configuration.contextPlanningDeadline
        + configuration.boundedHistoryContextDeadline,
      configuration.taskDeadline > configuration.boundedHistoryContextDeadline,
      configuration.maximumArtifacts > 0,
      configuration.maximumBytes > 0,
      configuration.maximumTextCharacters >= 0
    else {
      throw DesktopTaskCoordinatorError.invalidConfiguration
    }
    self.configuration = configuration
    self.journal = journal
  }

  public func begin(
    intent rawIntent: String,
    snapshot: InvocationSnapshot,
    requestedScope: ContextScope,
    allowedActions: Set<ActionClass> = [.read, .proposeDraft],
    approvalPolicy: ApprovalPolicy = .previewReversibleWrites,
    now: Date = Date()
  ) async throws -> PreparedDesktopTask {
    let locked = try await lockTarget(
      intent: rawIntent,
      snapshot: snapshot,
      allowedActions: allowedActions,
      approvalPolicy: approvalPolicy,
      now: now
    )
    try await markContextPlanning(taskID: locked.capsule.id, now: now)
    return try await prepareContext(
      taskID: locked.capsule.id,
      request: AgentContextRequest(
        scope: requestedScope,
        evidence: Self.defaultEvidence(for: requestedScope, snapshot: snapshot)
      ),
      now: now
    )
  }

  public func lockTarget(
    intent rawIntent: String,
    snapshot: InvocationSnapshot,
    taskID: UUID = UUID(),
    acpSessionID: String? = nil,
    allowedActions: Set<ActionClass> = [.read, .proposeDraft],
    approvalPolicy: ApprovalPolicy = .previewReversibleWrites,
    now: Date = Date()
  ) async throws -> LockedDesktopTask {
    let intent = rawIntent.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !intent.isEmpty else { throw DesktopTaskCoordinatorError.emptyIntent }
    do {
      try snapshot.window.validate(now: now)
      guard snapshot.pointedElement?.protectedContent != true else {
        throw DesktopTaskCoordinatorError.invalidSnapshot
      }
    } catch {
      throw DesktopTaskCoordinatorError.invalidSnapshot
    }

    let targetExpiry = min(
      snapshot.window.expiresAt,
      now.addingTimeInterval(configuration.targetLeaseDuration)
    )
    let targetLease = TargetLease(
      invocationSnapshotID: snapshot.id,
      window: snapshot.window,
      semanticTarget: Self.semanticTarget(in: snapshot),
      issuedAt: now,
      expiresAt: targetExpiry
    )
    do {
      try targetLease.validate(now: now)
    } catch {
      throw DesktopTaskCoordinatorError.invalidSnapshot
    }

    let manifestID = UUID()
    let taskDeadline = now.addingTimeInterval(configuration.taskDeadline)
    let capsule = TaskCapsule(
      id: taskID,
      createdAt: now,
      intent: intent,
      targetLeaseID: targetLease.id,
      contextManifestID: manifestID,
      desiredOutcome: intent,
      allowedActions: allowedActions,
      approvalPolicy: approvalPolicy,
      deadline: taskDeadline,
      acpSessionID: acpSessionID
    )
    let locked = LockedDesktopTask(
      capsule: capsule,
      targetLease: targetLease,
      mutationTarget: Self.mutationTarget(in: snapshot)
    )
    let ledger = try TaskLedger(capsule: capsule, now: now)
    try await ledger.transition(
      to: .targetLocked,
      actor: .host,
      reason: "immutable target lease issued",
      now: now
    )
    try await journal?.append(await ledger.events())
    tasks[taskID] = ActiveTask(
      locked: locked,
      ledger: ledger,
      contextRequest: nil,
      manifest: nil
    )
    return locked
  }

  public func markContextPlanning(taskID: UUID, now: Date = Date()) async throws {
    let task = try activeTask(id: taskID)
    let event = try await task.ledger.transition(
      to: .contextPlanning,
      actor: .agent,
      reason: "Agent session is selecting the minimum evidence set",
      now: now
    )
    try await journal?.append([event])
  }

  public func contextPlanningDeadline(taskID: UUID, now: Date = Date()) throws -> Date {
    let task = try activeTask(id: taskID)
    return min(
      task.locked.targetLease.expiresAt,
      now.addingTimeInterval(configuration.contextPlanningDeadline)
    )
  }

  public func prepareContext(
    taskID: UUID,
    request agentRequest: AgentContextRequest,
    now: Date = Date()
  ) async throws -> PreparedDesktopTask {
    try agentRequest.validate(now: now)
    guard var task = tasks[taskID] else {
      throw DesktopTaskCoordinatorError.taskNotFound
    }
    guard task.contextRequest == nil else {
      throw DesktopTaskCoordinatorError.manifestAlreadyAttached
    }
    let targetExpiry = task.locked.targetLease.expiresAt
    let budget = ContextBudget(
      maximumArtifacts: configuration.maximumArtifacts,
      maximumBytes: configuration.maximumBytes,
      maximumTextCharacters: configuration.maximumTextCharacters,
      deadline: min(
        targetExpiry,
        now.addingTimeInterval(
          agentRequest.scope.requiresExtendedCaptureDeadline
            ? configuration.boundedHistoryContextDeadline
            : configuration.contextDeadline
        )
      )
    )
    let request = ContextCaptureRequest(
      taskID: taskID,
      target: task.locked.targetLease,
      requestedScope: agentRequest.scope,
      budget: budget,
      requiredProviders: Self.providerKinds(for: agentRequest.evidence)
    )
    task.contextRequest = request
    tasks[taskID] = task
    return PreparedDesktopTask(
      capsule: task.locked.capsule,
      targetLease: task.locked.targetLease,
      mutationTarget: task.locked.mutationTarget,
      contextRequest: request
    )
  }

  public func attachContext(
    _ resolution: ContextResolution,
    to taskID: UUID,
    remoteTransmissionAllowed: Bool,
    desktopRecoveryVerified: Bool,
    pursuedScope: ContextScope? = nil,
    now: Date = Date()
  ) async throws -> ContextManifest {
    guard var task = tasks[taskID] else {
      throw DesktopTaskCoordinatorError.taskNotFound
    }
    guard task.manifest == nil else {
      throw DesktopTaskCoordinatorError.manifestAlreadyAttached
    }

    // The host may have had to widen the scope to acquire anything at all —
    // the pixel fallback for applications that expose no accessibility text.
    // The manifest is then sealed against the scope actually pursued, or its
    // lineage check would reject the very artifacts it is built from.
    guard var request = task.contextRequest else {
      throw DesktopTaskCoordinatorError.noUsableContext
    }
    if let pursuedScope, pursuedScope != request.requestedScope {
      request = ContextCaptureRequest(
        taskID: request.taskID,
        target: request.target,
        requestedScope: pursuedScope,
        budget: request.budget,
        coherenceGroup: request.coherenceGroup,
        requiredProviders: request.requiredProviders
      )
    }
    guard let resolvedScope = resolution.resolvedScope,
      !resolution.artifacts.isEmpty
    else {
      // Record which providers declined and why. Without this the ledger says
      // only "no usable context artifact", and the actual cause — a permission,
      // a changed window, an empty accessibility tree — is unrecoverable after
      // the fact.
      let causes =
        resolution.omissions
        .sorted { $0.key.rawValue < $1.key.rawValue }
        .map { "\($0.key.rawValue): \($0.value)" }
        .joined(separator: "; ")
      let event = try await task.ledger.transition(
        to: .failed,
        actor: .host,
        reason: causes.isEmpty
          ? "no usable context artifact"
          : "no usable context artifact (\(causes))",
        now: now
      )
      try await journal?.append([event])
      throw DesktopTaskCoordinatorError.noUsableContext
    }

    let degraded =
      resolvedScope != request.requestedScope
      || resolution.exhaustedBudget
      || resolution.artifacts.contains(where: { !$0.complete })
      || !resolution.omissions.isEmpty
    let omissionSummary = resolution.omissions
      .sorted { $0.key.rawValue < $1.key.rawValue }
      .map { "\($0.key.rawValue): \($0.value)" }
      .joined(separator: "; ")
    let omittedScopes: [ContextScope: String] =
      degraded
      ? [
        request.requestedScope: omissionSummary.isEmpty
          ? "requested scope was not fully resolved" : omissionSummary
      ]
      : [:]
    let digest = Self.manifestDigest(
      taskID: taskID,
      targetLeaseID: task.locked.targetLease.id,
      requestedScope: request.requestedScope,
      resolvedScope: resolvedScope,
      artifacts: resolution.artifacts,
      omittedScopes: omittedScopes
    )
    let manifest = ContextManifest(
      id: task.locked.capsule.contextManifestID,
      taskID: taskID,
      targetLeaseID: task.locked.targetLease.id,
      requestedScope: request.requestedScope,
      resolvedScope: resolvedScope,
      artifacts: resolution.artifacts,
      acquisitionReceiptIDs: resolution.receipts.map(\.id),
      omittedScopes: omittedScopes,
      budget: request.budget,
      remoteTransmissionAllowed: remoteTransmissionAllowed,
      coherent: Set(resolution.artifacts.map(\.coherenceGroup)).count == 1,
      digest: digest
    )
    try manifest.validate(now: now)
    let event = try await task.ledger.transition(
      to: degraded ? .degraded : .contextReady,
      actor: .host,
      reason: degraded
        ? "Agent-requested context resolved with omissions scope=\(request.requestedScope.rawValue) providers=\(Self.providerList(request.requiredProviders))"
        : "Agent-requested context resolved scope=\(request.requestedScope.rawValue) providers=\(Self.providerList(request.requiredProviders))",
      inputDigest: manifest.digest,
      artifactIDs: manifest.artifacts.map(\.id),
      desktopRecoveryVerified: desktopRecoveryVerified,
      now: now
    )
    try await journal?.append([event])
    task.manifest = manifest
    tasks[taskID] = task
    return manifest
  }

  public func markAgentRunning(taskID: UUID, now: Date = Date()) async throws {
    let task = try activeTask(id: taskID)
    let event = try await task.ledger.transition(
      to: .agentRunning,
      actor: .agent,
      reason: "ACP session accepted task capsule",
      now: now
    )
    try await journal?.append([event])
  }

  /// Advances a task whose Agent explicitly selected the typed no-context
  /// route. This is not a Host fallback: the ledger records the Agent-owned
  /// decision and no manifest or artifact is created.
  public func markAgentRunningWithoutContext(
    taskID: UUID,
    now: Date = Date()
  ) async throws {
    let task = try activeTask(id: taskID)
    let event = try await task.ledger.transition(
      to: .agentRunning,
      actor: .agent,
      reason: "Agent explicitly selected no external context",
      now: now
    )
    try await journal?.append([event])
  }

  public func markAwaitingPermission(taskID: UUID, now: Date = Date()) async throws {
    let task = try activeTask(id: taskID)
    let event = try await task.ledger.transition(
      to: .awaitingPermission,
      actor: .host,
      reason: "generated draft is waiting for an explicit insertion gesture",
      now: now
    )
    try await journal?.append([event])
  }

  public func markExecuting(taskID: UUID, now: Date = Date()) async throws {
    let task = try activeTask(id: taskID)
    let event = try await task.ledger.transition(
      to: .executing,
      actor: .executor,
      reason: "user approved one exact reversible draft insertion",
      now: now
    )
    try await journal?.append([event])
  }

  public func markVerifying(taskID: UUID, now: Date = Date()) async throws {
    let task = try activeTask(id: taskID)
    let event = try await task.ledger.transition(
      to: .verifying,
      actor: .verifier,
      reason: "reading the leased field back after mutation",
      now: now
    )
    try await journal?.append([event])
  }

  public func markReversibleWindow(
    taskID: UUID,
    receipt: MutationReceipt,
    now: Date = Date()
  ) async throws {
    let task = try activeTask(id: taskID)
    let event = try await task.ledger.transition(
      to: .reversibleWindow,
      actor: .verifier,
      reason: "verified insertion is available for bounded compare-and-swap undo",
      artifactIDs: receipt.postcondition.evidenceArtifactIDs,
      now: now
    )
    try await journal?.append([event])
  }

  public func markRestoring(taskID: UUID, now: Date = Date()) async throws {
    let task = try activeTask(id: taskID)
    let event = try await task.ledger.transition(
      to: .restoring,
      actor: .user,
      reason: "user requested the bounded inverse operation",
      now: now
    )
    try await journal?.append([event])
  }

  public func completeMutation(
    taskID: UUID,
    succeeded: Bool,
    reason: String,
    now: Date = Date()
  ) async throws {
    let task = try activeTask(id: taskID)
    let event = try await task.ledger.transition(
      to: succeeded ? .succeeded : .partial,
      actor: .verifier,
      reason: reason,
      now: now
    )
    try await journal?.append([event])
  }

  public func completeReadOnly(
    taskID: UUID,
    succeeded: Bool,
    reason: String,
    now: Date = Date()
  ) async throws {
    let task = try activeTask(id: taskID)
    let event = try await task.ledger.transition(
      to: succeeded ? .succeeded : .failed,
      actor: .verifier,
      reason: reason,
      now: now
    )
    try await journal?.append([event])
  }

  public func fail(taskID: UUID, reason: String, now: Date = Date()) async throws {
    let task = try activeTask(id: taskID)
    let event = try await task.ledger.transition(
      to: .failed,
      actor: .host,
      reason: reason,
      now: now
    )
    try await journal?.append([event])
  }

  public func cancel(taskID: UUID, reason: String, now: Date = Date()) async throws {
    let task = try activeTask(id: taskID)
    let event = try await task.ledger.transition(
      to: .cancelled,
      actor: .user,
      reason: reason,
      now: now
    )
    try await journal?.append([event])
  }

  public func verifyCleanup(taskID: UUID, reason: String, now: Date = Date()) async throws {
    let task = try activeTask(id: taskID)
    let event = try await task.ledger.transition(
      to: .cleanupVerified,
      actor: .verifier,
      reason: reason,
      desktopRecoveryVerified: true,
      now: now
    )
    try await journal?.append([event])
    let events = await task.ledger.events()
    archivedEvents[taskID] = events
    archiveOrder.append(taskID)
    tasks.removeValue(forKey: taskID)
    while archiveOrder.count > 256 {
      archivedEvents.removeValue(forKey: archiveOrder.removeFirst())
    }
  }

  public func events(taskID: UUID, after sequence: UInt64? = nil) async throws -> [TaskEvent] {
    if let task = tasks[taskID] {
      return await task.ledger.events(after: sequence)
    }
    guard let events = archivedEvents[taskID] else {
      throw DesktopTaskCoordinatorError.taskNotFound
    }
    guard let sequence else { return events }
    return events.filter { $0.sequence > sequence }
  }

  private func activeTask(id: UUID) throws -> ActiveTask {
    guard let task = tasks[id] else { throw DesktopTaskCoordinatorError.taskNotFound }
    return task
  }

  private static func defaultEvidence(
    for scope: ContextScope,
    snapshot: InvocationSnapshot
  ) -> [AgentEvidenceKind] {
    switch scope {
    case .selection where snapshot.selectedText?.isEmpty == false:
      [.selectedText]
    case .window:
      [.currentFrame]
    case .boundedHistory:
      [.visualHistory]
    default:
      [.accessibility]
    }
  }

  private static func providerKinds(
    for evidence: [AgentEvidenceKind]
  ) -> Set<ContextProviderKind> {
    Set(
      evidence.map { kind in
        switch kind {
        case .selectedText: .selection
        case .accessibility: .accessibility
        case .currentFrame, .visualHistory: .longview
        }
      })
  }

  private static func providerList(_ providers: Set<ContextProviderKind>) -> String {
    providers.map(\.rawValue).sorted().joined(separator: ",")
  }

  private static func manifestDigest(
    taskID: UUID,
    targetLeaseID: UUID,
    requestedScope: ContextScope,
    resolvedScope: ContextScope,
    artifacts: [ContextArtifact],
    omittedScopes: [ContextScope: String]
  ) -> String {
    var components = [
      taskID.uuidString,
      targetLeaseID.uuidString,
      requestedScope.rawValue,
      resolvedScope.rawValue,
    ]
    components.append(
      contentsOf:
        artifacts
        .sorted { $0.id.uuidString < $1.id.uuidString }
        .map { "\($0.id.uuidString):\($0.contentDigest)" })
    components.append(
      contentsOf:
        omittedScopes
        .sorted { $0.key.rawValue < $1.key.rawValue }
        .map { "\($0.key.rawValue):\($0.value)" })
    return SHA256.hash(data: Data(components.joined(separator: "\n").utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  /// Chrome roles carry no task content — a pointer resting on the menu bar or
  /// a toolbar would otherwise become the target, and the agent would receive
  /// menu titles instead of the document the user is looking at.
  private static let chromeRoles: Set<String> = [
    "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem", "AXToolbar", "AXDockItem",
  ]

  /// Prefers what the pointer is on, but falls back to keyboard focus when the
  /// pointer rests on window chrome rather than on content.
  private static func semanticTarget(in snapshot: InvocationSnapshot) -> AXElementFingerprint? {
    if let pointed = snapshot.pointedElement, !chromeRoles.contains(pointed.role) {
      return pointed
    }
    return snapshot.focusedElement ?? snapshot.pointedElement
  }

  private static func mutationTarget(in snapshot: InvocationSnapshot) -> AXElementFingerprint? {
    [snapshot.focusedElement, snapshot.pointedElement]
      .compactMap { $0 }
      .first { element in
        !element.protectedContent
          && (element.role == "AXTextField" || element.role == "AXTextArea")
          && (element.identifier != nil || element.frame != nil)
      }
  }
}

extension PostconditionVerdict {
  fileprivate var evidenceArtifactIDs: [UUID] {
    switch self {
    case .verified(let evidenceArtifactIDs), .failed(_, let evidenceArtifactIDs):
      evidenceArtifactIDs
    }
  }
}
