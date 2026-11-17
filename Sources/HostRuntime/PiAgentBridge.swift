import ACPGateway
import CryptoKit
import Foundation
import MienContracts
import OSLog

public struct PiAgentBridgeConfiguration: Sendable {
  public let process: ACPProcessConfiguration
  public let clientInfo: ACPImplementation
  public let maximumContextBytes: Int
  public let maximumRestartsPerMinute: Int

  public init(
    process: ACPProcessConfiguration,
    clientInfo: ACPImplementation,
    maximumContextBytes: Int = 12 * 1_024 * 1_024,
    maximumRestartsPerMinute: Int = 3
  ) throws {
    try process.validate()
    guard maximumContextBytes > 0,
      (1...10).contains(maximumRestartsPerMinute)
    else {
      throw PiAgentBridgeError.invalidConfiguration
    }
    self.process = process
    self.clientInfo = clientInfo
    self.maximumContextBytes = maximumContextBytes
    self.maximumRestartsPerMinute = maximumRestartsPerMinute
  }
}

public enum PiAgentBridgeError: Error, Equatable, Sendable {
  case invalidConfiguration
  case inconsistentTask
  case contextTransmissionDenied
  case artifactUnavailable
  case artifactDigestMismatch
  case unsupportedArtifact
  case contextBudgetExceeded
  case restartCircuitOpen
  case taskDeadlineExceeded
  case taskSessionAlreadyOpen
  case taskSessionUnavailable
  case invalidAgentProtocol
  case agentProtocolViolation(AgentProtocolViolation)
  case unavailableEvidenceRequested
  case unsupportedContextRequest
  case unexpectedAgentStopReason
  case invalidModelPreference
  case preferredModelUnavailable(String)
  case sessionCleanupFailed
  case authenticationRequired
  case modelCatalogUnavailable
}

/// Privacy-safe, stable failure codes for the two-step Agent tool protocol.
/// These distinguish model non-compliance from transport, context, and Host
/// failures without retaining user input, reasoning, or tool payloads.
public enum AgentProtocolViolation: String, Error, Equatable, Sendable {
  case invalidEnvelope
  case unexpectedMethod
  case duplicateContextDecision
  case malformedContextDecision
  case outcomeBeforeContextDecision
  case duplicateOutcome
  case malformedOutcome
  case missingContextDecision
  case missingOutcome
}

enum PiAgentRuntimeRPCErrorCode {
  static let missingContextDecision = -32_010
  static let missingOutcome = -32_011
  static let authenticationRequired = -32_021
  static let modelCatalogUnavailable = -32_022
}

public enum AgentEvidenceAvailability: String, Codable, Equatable, Sendable {
  case available
  case requiresAuthorization
}

public struct AgentEvidenceCapability: Codable, Equatable, Sendable {
  public let kind: AgentEvidenceKind
  public let availability: AgentEvidenceAvailability

  public init(kind: AgentEvidenceKind, availability: AgentEvidenceAvailability) {
    self.kind = kind
    self.availability = availability
  }
}

public struct AgentTurnResult: Equatable, Sendable {
  public let contextDecision: AgentContextDecision
  public let outcome: AgentOutcome

  public init(contextDecision: AgentContextDecision, outcome: AgentOutcome) {
    self.contextDecision = contextDecision
    self.outcome = outcome
  }
}

public typealias AgentContextToolHandler =
  @Sendable (AgentContextDecision) async throws -> [ACPContentBlock]

actor AgentTurnExchange {
  private let sessionID: String
  private let catalog: [AgentContextRequest]
  private let contextHandler: AgentContextToolHandler
  private var contextDecision: AgentContextDecision?
  private var outcome: AgentOutcome?
  private var failure: Error?

  init(
    sessionID: String,
    catalog: [AgentContextRequest],
    contextHandler: @escaping AgentContextToolHandler
  ) {
    self.sessionID = sessionID
    self.catalog = catalog
    self.contextHandler = contextHandler
  }

  func handle(_ message: JSONRPCIncomingMessage) async throws -> JSONValue {
    do {
      guard case .object(let parameters)? = message.params,
        case .string(let incomingSessionID)? = parameters["sessionId"],
        incomingSessionID == sessionID,
        let method = message.method
      else {
        throw PiAgentBridgeError.agentProtocolViolation(.invalidEnvelope)
      }
      switch method {
      case "mien/request_context":
        guard contextDecision == nil else {
          throw PiAgentBridgeError.agentProtocolViolation(.duplicateContextDecision)
        }
        guard let value = parameters["decision"] else {
          throw PiAgentBridgeError.agentProtocolViolation(.malformedContextDecision)
        }
        let decision: AgentContextDecision = try Self.decode(
          value,
          violation: .malformedContextDecision
        )
        do {
          try decision.validate()
        } catch {
          throw PiAgentBridgeError.agentProtocolViolation(.malformedContextDecision)
        }
        if let request = decision.request,
          !catalog.contains(where: request.matchesCatalogEntry)
        {
          throw PiAgentBridgeError.unsupportedContextRequest
        }
        contextDecision = decision
        let content = try await contextHandler(decision)
        guard !content.isEmpty else {
          throw PiAgentBridgeError.artifactUnavailable
        }
        return .object(["content": .array(content.map(Self.jsonValue))])
      case "mien/submit_outcome":
        guard contextDecision != nil else {
          throw PiAgentBridgeError.agentProtocolViolation(.outcomeBeforeContextDecision)
        }
        guard outcome == nil else {
          throw PiAgentBridgeError.agentProtocolViolation(.duplicateOutcome)
        }
        guard let value = parameters["outcome"] else {
          throw PiAgentBridgeError.agentProtocolViolation(.malformedOutcome)
        }
        let decoded: AgentOutcome = try Self.decode(value, violation: .malformedOutcome)
        do {
          try decoded.validate()
        } catch {
          throw PiAgentBridgeError.agentProtocolViolation(.malformedOutcome)
        }
        outcome = decoded
        return .object(["accepted": .bool(true)])
      default:
        throw PiAgentBridgeError.agentProtocolViolation(.unexpectedMethod)
      }
    } catch {
      // Preserve the first failure: later transport fallout must not replace
      // the exact Host boundary that rejected the turn.
      if failure == nil { failure = error }
      throw error
    }
  }

  func recordedFailure() -> Error? {
    failure
  }

  func validatedResult() throws -> AgentTurnResult {
    if let failure { throw failure }
    guard let contextDecision else {
      throw PiAgentBridgeError.agentProtocolViolation(.missingContextDecision)
    }
    guard let outcome else {
      throw PiAgentBridgeError.agentProtocolViolation(.missingOutcome)
    }
    return AgentTurnResult(contextDecision: contextDecision, outcome: outcome)
  }

  private static func decode<Value: Decodable>(
    _ value: JSONValue,
    violation: AgentProtocolViolation
  ) throws -> Value {
    do {
      return try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    } catch {
      throw PiAgentBridgeError.agentProtocolViolation(violation)
    }
  }

  private static func jsonValue(_ block: ACPContentBlock) -> JSONValue {
    switch block {
    case .text(let text):
      .object(["type": .string("text"), "text": .string(text)])
    case .image(let data, let mimeType):
      .object([
        "type": .string("image"),
        "data": .string(data),
        "mimeType": .string(mimeType),
      ])
    case .resourceLink(let name, let uri, let mimeType):
      .object([
        "type": .string("resource_link"),
        "name": .string(name),
        "uri": .string(uri),
        "mimeType": mimeType.map(JSONValue.string) ?? .null,
      ])
    }
  }
}

/// Owns the one-to-one relationship between a visible Agent conversation and
/// its currently authorized Host task. Releasing a completed Host task and
/// invalidating the Agent conversation are intentionally separate operations.
struct PiConversationSessionState: Sendable {
  struct Conversation: Sendable, Equatable {
    let sessionID: String
    let agentDefaultModelID: String
    let modelConfiguration: ACPAgentModelConfiguration
    let preferredModelID: String?

    var effectiveModelID: String {
      preferredModelID ?? agentDefaultModelID
    }
  }

  struct TaskBinding: Sendable, Equatable {
    let conversationID: UUID
    let sessionID: String
    let closesAfterTask: Bool
  }

  private(set) var conversations: [UUID: Conversation] = [:]
  private(set) var taskBindings: [UUID: TaskBinding] = [:]

  func conversation(id: UUID) -> Conversation? {
    conversations[id]
  }

  func binding(taskID: UUID) -> TaskBinding? {
    taskBindings[taskID]
  }

  mutating func registerConversation(
    id: UUID,
    sessionID: String,
    agentDefaultModelID: String,
    modelConfiguration: ACPAgentModelConfiguration,
    preferredModelID: String?
  ) {
    conversations[id] = Conversation(
      sessionID: sessionID,
      agentDefaultModelID: agentDefaultModelID,
      modelConfiguration: modelConfiguration,
      preferredModelID: preferredModelID
    )
  }

  /// Changes only the model owned by an idle conversation. The caller applies
  /// the ACP configuration first and commits the returned configuration here;
  /// an in-flight Host task can therefore never observe a mid-turn model swap.
  mutating func updateModelSelection(
    conversationID: UUID,
    configuration: ACPAgentModelConfiguration,
    preferredModelID: String?
  ) throws {
    guard let conversation = conversations[conversationID] else {
      throw PiAgentBridgeError.taskSessionUnavailable
    }
    guard !taskBindings.values.contains(where: { $0.conversationID == conversationID }) else {
      throw PiAgentBridgeError.taskSessionAlreadyOpen
    }
    conversations[conversationID] = Conversation(
      sessionID: conversation.sessionID,
      agentDefaultModelID: conversation.agentDefaultModelID,
      modelConfiguration: configuration,
      preferredModelID: preferredModelID
    )
  }

  mutating func bind(
    taskID: UUID,
    conversationID: UUID,
    sessionID: String,
    closesAfterTask: Bool
  ) throws {
    guard taskBindings[taskID] == nil,
      !taskBindings.values.contains(where: { $0.conversationID == conversationID }),
      conversations[conversationID]?.sessionID == sessionID
    else {
      throw PiAgentBridgeError.taskSessionAlreadyOpen
    }
    taskBindings[taskID] = TaskBinding(
      conversationID: conversationID,
      sessionID: sessionID,
      closesAfterTask: closesAfterTask
    )
  }

  /// Ends one persistent Host task while preserving the Agent conversation for
  /// the next fresh task. Legacy one-task sessions cannot use this operation.
  @discardableResult
  mutating func releaseTaskBindingPreservingConversation(taskID: UUID) throws -> TaskBinding {
    guard let binding = taskBindings[taskID], !binding.closesAfterTask,
      conversations[binding.conversationID]?.sessionID == binding.sessionID
    else {
      throw PiAgentBridgeError.taskSessionUnavailable
    }
    taskBindings.removeValue(forKey: taskID)
    return binding
  }

  @discardableResult
  mutating func completeTask(taskID: UUID) -> TaskBinding? {
    guard let binding = taskBindings.removeValue(forKey: taskID) else { return nil }
    if binding.closesAfterTask {
      conversations.removeValue(forKey: binding.conversationID)
    }
    return binding
  }

  /// Invalidates both the Agent session and every Host binding that refers to
  /// it. Callers must close the returned ACP session before claiming cleanup.
  mutating func invalidateConversation(id: UUID) -> Conversation? {
    guard let conversation = conversations.removeValue(forKey: id) else { return nil }
    taskBindings = taskBindings.filter { $0.value.conversationID != id }
    return conversation
  }

  mutating func removeAll() {
    conversations.removeAll()
    taskBindings.removeAll()
  }
}

public actor PiAgentBridge {
  private let configuration: PiAgentBridgeConfiguration
  private var runtime: ACPClientRuntime?
  private var restartDates: [Date] = []
  private var sessionState = PiConversationSessionState()
  private var connectedAgent: ACPImplementation?
  private let logger = Logger(
    subsystem: "io.github.kohoj.mien",
    category: "agent-model"
  )

  public init(configuration: PiAgentBridgeConfiguration) {
    self.configuration = configuration
  }

  public func connect(now: Date = Date()) async throws -> ACPImplementation? {
    _ = try await readyRuntime(now: now)
    return connectedAgent
  }

  /// Opens a prompt-free, private session solely to read the Agent's live model
  /// configuration, then closes it before returning. No static model list is
  /// maintained by the Host.
  public func discoverModels(now: Date = Date()) async throws -> AgentModelCatalog {
    let runtime = try await readyRuntime(now: now)
    let session: ACPNewSessionResult
    do {
      session = try await runtime.newSession(
        workingDirectory: configuration.process.workingDirectoryURL
      )
    } catch {
      let normalized = Self.normalizedRuntimeError(error)
      if !Self.sessionCreationWasRejected(normalized) {
        await discardRuntime(now: now)
      }
      throw normalized
    }
    do {
      let catalog = try session.agentModelConfiguration().catalog
      try await closeUntrackedSession(
        sessionID: session.sessionId,
        runtime: runtime,
        now: now
      )
      logger.info(
        "live model catalog loaded optionCount=\(catalog.options.count, privacy: .public) defaultModelID=\(catalog.currentModelID, privacy: .public)"
      )
      return catalog
    } catch {
      if error as? PiAgentBridgeError != .sessionCleanupFailed {
        try await closeUntrackedSession(
          sessionID: session.sessionId,
          runtime: runtime,
          now: now
        )
      }
      throw error
    }
  }

  public func openTaskSession(
    taskID: UUID,
    workingDirectory: URL,
    preferredModelID: String? = nil,
    now: Date = Date()
  ) async throws -> String {
    try await openSession(
      taskID: taskID,
      conversationID: taskID,
      workingDirectory: workingDirectory,
      preferredModelID: preferredModelID,
      closesAfterTask: true,
      now: now
    )
  }

  /// Retains exactly one Agent session across a visible conversation while
  /// every submitted turn remains an independently authorized Host task.
  public func openConversationTaskSession(
    taskID: UUID,
    conversationID: UUID,
    workingDirectory: URL,
    preferredModelID: String? = nil,
    now: Date = Date()
  ) async throws -> String {
    try await openSession(
      taskID: taskID,
      conversationID: conversationID,
      workingDirectory: workingDirectory,
      preferredModelID: preferredModelID,
      closesAfterTask: false,
      now: now
    )
  }

  private func openSession(
    taskID: UUID,
    conversationID: UUID,
    workingDirectory: URL,
    preferredModelID: String?,
    closesAfterTask: Bool,
    now: Date
  ) async throws -> String {
    guard sessionState.binding(taskID: taskID) == nil else {
      throw PiAgentBridgeError.taskSessionAlreadyOpen
    }
    guard preferredModelID?.isEmpty != true else {
      throw PiAgentBridgeError.invalidModelPreference
    }
    let runtime = try await readyRuntime(now: now)
    if var conversation = sessionState.conversation(id: conversationID) {
      if conversation.preferredModelID != preferredModelID {
        let requestedModelID = preferredModelID ?? conversation.agentDefaultModelID
        guard conversation.modelConfiguration.catalog.contains(requestedModelID) else {
          throw PiAgentBridgeError.preferredModelUnavailable(requestedModelID)
        }
        let applied = try await runtime.selectModel(
          sessionID: conversation.sessionID,
          configurationID: conversation.modelConfiguration.configID,
          modelID: requestedModelID
        )
        try sessionState.updateModelSelection(
          conversationID: conversationID,
          configuration: applied,
          preferredModelID: preferredModelID
        )
        guard let updated = sessionState.conversation(id: conversationID) else {
          throw PiAgentBridgeError.taskSessionUnavailable
        }
        conversation = updated
        logger.info(
          "conversation model updated conversationID=\(conversationID.uuidString, privacy: .public) modelSource=\(preferredModelID == nil ? "agent-default" : "user-preference", privacy: .public) modelID=\(conversation.effectiveModelID, privacy: .public)"
        )
      }
      try sessionState.bind(
        taskID: taskID,
        conversationID: conversationID,
        sessionID: conversation.sessionID,
        closesAfterTask: closesAfterTask
      )
      logger.info(
        "conversation session reused taskID=\(taskID.uuidString, privacy: .public) conversationID=\(conversationID.uuidString, privacy: .public) modelID=\(conversation.effectiveModelID, privacy: .public)"
      )
      return conversation.sessionID
    }
    let session: ACPNewSessionResult
    do {
      session = try await runtime.newSession(workingDirectory: workingDirectory)
    } catch {
      let normalized = Self.normalizedRuntimeError(error)
      if !Self.sessionCreationWasRejected(normalized) {
        await discardRuntime(now: now)
      }
      throw normalized
    }
    do {
      let initialConfiguration = try session.agentModelConfiguration()
      var appliedConfiguration = initialConfiguration
      if let preferredModelID {
        guard initialConfiguration.catalog.contains(preferredModelID) else {
          throw PiAgentBridgeError.preferredModelUnavailable(preferredModelID)
        }
        appliedConfiguration = try await runtime.selectModel(
          sessionID: session.sessionId,
          configurationID: initialConfiguration.configID,
          modelID: preferredModelID
        )
      }
      sessionState.registerConversation(
        id: conversationID,
        sessionID: session.sessionId,
        agentDefaultModelID: initialConfiguration.catalog.currentModelID,
        modelConfiguration: appliedConfiguration,
        preferredModelID: preferredModelID
      )
      try sessionState.bind(
        taskID: taskID,
        conversationID: conversationID,
        sessionID: session.sessionId,
        closesAfterTask: closesAfterTask
      )
      logger.info(
        "conversation session configured taskID=\(taskID.uuidString, privacy: .public) conversationID=\(conversationID.uuidString, privacy: .public) modelSource=\(preferredModelID == nil ? "agent-default" : "user-preference", privacy: .public) modelID=\(preferredModelID ?? "agent-default", privacy: .public)"
      )
      return session.sessionId
    } catch {
      try await closeUntrackedSession(
        sessionID: session.sessionId,
        runtime: runtime,
        now: now
      )
      throw error
    }
  }

  /// Runs one user turn through Pi's tool loop. The Host provides capability
  /// facts and typed tool implementations; only the Agent interprets the
  /// user's verbatim input and decides which evidence to request.
  public func runTurn(
    taskID: UUID,
    userInput: String,
    target: TargetLease,
    capabilities: [AgentEvidenceCapability],
    deadline: Date,
    contextHandler: @escaping AgentContextToolHandler
  ) async throws -> AgentTurnResult {
    guard let binding = sessionState.binding(taskID: taskID), let runtime else {
      throw PiAgentBridgeError.taskSessionUnavailable
    }
    let uniqueCapabilities = Dictionary(
      capabilities.map { ($0.kind, $0) },
      uniquingKeysWith: { first, _ in first }
    ).values.sorted { $0.kind.rawValue < $1.kind.rawValue }
    let catalog = AgentContextRequest.supportedCatalog(
      availableEvidence: Set(uniqueCapabilities.map(\.kind))
    )
    let exchange = AgentTurnExchange(
      sessionID: binding.sessionID,
      catalog: catalog,
      contextHandler: contextHandler
    )
    await runtime.installInboundRequestHandler(
      sessionID: binding.sessionID,
      handler: { message in try await exchange.handle(message) }
    )
    var promptSettled = false
    do {
      let remainingMilliseconds = Int64(max(0, deadline.timeIntervalSinceNow) * 1_000)
      guard remainingMilliseconds > 0 else {
        throw PiAgentBridgeError.taskDeadlineExceeded
      }
      let result = try await runtime.prompt(
        sessionID: binding.sessionID,
        content: try turnContent(
          userInput: userInput,
          target: target,
          capabilities: uniqueCapabilities,
          validRequests: catalog
        ),
        timeout: .milliseconds(remainingMilliseconds)
      )
      promptSettled = true
      guard result.stopReason == .endTurn else {
        throw PiAgentBridgeError.unexpectedAgentStopReason
      }
      let turnResult = try await exchange.validatedResult()
      let contextKind = turnResult.contextDecision.kind.rawValue
      let outcomeKind = turnResult.outcome.kind.rawValue
      logger.info(
        "agent turn protocol completed taskID=\(taskID.uuidString, privacy: .public) contextDecision=\(contextKind, privacy: .public) outcome=\(outcomeKind, privacy: .public)"
      )
      await runtime.removeInboundRequestHandler(sessionID: binding.sessionID)
      _ = sessionState.completeTask(taskID: taskID)
      if binding.closesAfterTask {
        try await runtime.closeSession(sessionID: binding.sessionID)
      }
      return turnResult
    } catch is CancellationError {
      await runtime.removeInboundRequestHandler(sessionID: binding.sessionID)
      await invalidateConversation(containingTaskID: taskID)
      throw CancellationError()
    } catch {
      // A child RPC error can be the projection of a more precise rejection
      // recorded by the Host's typed tool boundary. Prefer that stable local
      // error over the deliberately generic wire message.
      let recordedFailure = await exchange.recordedFailure()
      let effectiveError = recordedFailure ?? Self.normalizedRuntimeError(error)
      if effectiveError as? PiAgentBridgeError == .authenticationRequired {
        logger.error(
          "agent authentication required taskID=\(taskID.uuidString, privacy: .public) conversationID=\(binding.conversationID.uuidString, privacy: .public)"
        )
      }
      if case .agentProtocolViolation(let violation) = effectiveError as? PiAgentBridgeError {
        logger.error(
          "agent turn protocol failed taskID=\(taskID.uuidString, privacy: .public) violation=\(violation.rawValue, privacy: .public)"
        )
      }
      await runtime.removeInboundRequestHandler(sessionID: binding.sessionID)
      if promptSettled || Self.agentSessionIsIdle(after: error) {
        try? releaseTaskBindingPreservingConversation(taskID: taskID)
      } else {
        await invalidateConversation(containingTaskID: taskID)
      }
      throw effectiveError
    }
  }

  public func stop() async {
    if let runtime { await runtime.stop() }
    runtime = nil
    connectedAgent = nil
    sessionState.removeAll()
  }

  /// Releases a completed or Host-refused task while retaining the underlying
  /// Agent conversation. The next turn must still open a fresh task binding.
  public func releaseTaskBindingPreservingConversation(taskID: UUID) throws {
    let binding = try sessionState.releaseTaskBindingPreservingConversation(taskID: taskID)
    logger.info(
      "conversation task binding released taskID=\(taskID.uuidString, privacy: .public) conversationID=\(binding.conversationID.uuidString, privacy: .public)"
    )
  }

  /// Invalidates the entire Agent conversation containing this task. This is
  /// the only task-scoped operation that closes a persistent ACP session.
  public func invalidateConversation(containingTaskID taskID: UUID) async {
    guard let binding = sessionState.binding(taskID: taskID) else { return }
    await terminateConversation(
      conversationID: binding.conversationID,
      logDescription: "invalidated"
    )
  }

  public func conversationIsValid(conversationID: UUID) -> Bool {
    sessionState.conversation(id: conversationID) != nil
  }

  public func activityUpdates(taskID: UUID) async throws -> AsyncStream<ACPAgentActivityUpdate> {
    guard let binding = sessionState.binding(taskID: taskID), let runtime else {
      throw PiAgentBridgeError.taskSessionUnavailable
    }
    return await runtime.activityUpdates(sessionID: binding.sessionID)
  }

  public func closeConversation(conversationID: UUID) async {
    await terminateConversation(conversationID: conversationID, logDescription: "closed")
  }

  private func terminateConversation(
    conversationID: UUID,
    logDescription: String
  ) async {
    guard let conversation = sessionState.invalidateConversation(id: conversationID) else { return }
    guard let runtime else { return }
    do {
      try await runtime.closeSession(sessionID: conversation.sessionID)
      logger.info(
        "conversation session \(logDescription, privacy: .public) conversationID=\(conversationID.uuidString, privacy: .public)"
      )
    } catch {
      logger.error(
        "conversation session cleanup failed conversationID=\(conversationID.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)"
      )
      await discardRuntime(now: Date())
    }
  }

  private func readyRuntime(now: Date) async throws -> ACPClientRuntime {
    if let runtime, case .ready = await runtime.state { return runtime }

    restartDates = restartDates.filter { now.timeIntervalSince($0) < 60 }
    guard restartDates.count < configuration.maximumRestartsPerMinute else {
      throw PiAgentBridgeError.restartCircuitOpen
    }
    restartDates.append(now)
    let runtime = try ACPClientRuntime(
      configuration: configuration.process,
      clientInfo: configuration.clientInfo
    )
    let result: ACPInitializeResult
    do {
      result = try await runtime.start(now: now)
    } catch {
      let normalized = Self.normalizedRuntimeError(error)
      if normalized as? PiAgentBridgeError == .authenticationRequired {
        restartDates.removeAll { $0 == now }
      }
      throw normalized
    }
    connectedAgent = result.agentInfo
    self.runtime = runtime
    return runtime
  }

  private func discardRuntime(now: Date) async {
    if let runtime { await runtime.stop() }
    runtime = nil
    connectedAgent = nil
    sessionState.removeAll()
    restartDates = restartDates.filter { now.timeIntervalSince($0) < 60 }
  }

  private func closeUntrackedSession(
    sessionID: String,
    runtime: ACPClientRuntime,
    now: Date
  ) async throws {
    do {
      try await runtime.closeSession(sessionID: sessionID)
    } catch {
      await discardRuntime(now: now)
      throw PiAgentBridgeError.sessionCleanupFailed
    }
  }

  /// These typed errors occur before the child allocates a session. A failed
  /// Settings discovery must not terminate another conversation's active turn.
  private static func sessionCreationWasRejected(_ error: Error) -> Bool {
    switch error as? PiAgentBridgeError {
    case .authenticationRequired, .modelCatalogUnavailable:
      true
    default:
      false
    }
  }

  /// A JSON-RPC error response from the child is emitted only after its
  /// session/prompt handler has unwound and cleared `activePrompt`. Transport
  /// loss, timeout, and cancellation remain uncertain and invalidate the
  /// conversation instead.
  private static func agentSessionIsIdle(after error: Error) -> Bool {
    switch error as? ACPConnectionError {
    case .remoteError:
      true
    default:
      false
    }
  }

  /// Maps only stable child-owned numeric codes. Error messages are
  /// intentionally ignored so prose can never become protocol truth.
  static func normalizedRuntimeError(_ error: Error) -> Error {
    guard case .remoteError(let code, _) = error as? ACPConnectionError else {
      return error
    }
    switch code {
    case PiAgentRuntimeRPCErrorCode.missingContextDecision:
      return PiAgentBridgeError.agentProtocolViolation(.missingContextDecision)
    case PiAgentRuntimeRPCErrorCode.missingOutcome:
      return PiAgentBridgeError.agentProtocolViolation(.missingOutcome)
    case PiAgentRuntimeRPCErrorCode.authenticationRequired:
      return PiAgentBridgeError.authenticationRequired
    case PiAgentRuntimeRPCErrorCode.modelCatalogUnavailable:
      return PiAgentBridgeError.modelCatalogUnavailable
    default:
      return error
    }
  }

  private func turnContent(
    userInput: String,
    target: TargetLease,
    capabilities: [AgentEvidenceCapability],
    validRequests: [AgentContextRequest]
  ) throws -> [ACPContentBlock] {
    struct TargetMetadata: Encodable {
      let bundleIdentifier: String
      let semanticRole: String?
      let semanticAncestorRoles: [String]
    }
    struct TurnEnvelope: Encodable {
      let schemaVersion = 1
      let userInput: String
      let target: TargetMetadata
      let evidenceCapabilities: [AgentEvidenceCapability]
      let validContextRequests: [AgentContextRequest]
    }
    let envelope = TurnEnvelope(
      userInput: userInput,
      target: TargetMetadata(
        bundleIdentifier: target.window.bundleIdentifier,
        semanticRole: target.semanticTarget?.role,
        semanticAncestorRoles: target.semanticTarget?.ancestorRoles ?? []
      ),
      evidenceCapabilities: capabilities,
      validContextRequests: validRequests
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(envelope)
    guard let text = String(data: data, encoding: .utf8) else {
      throw PiAgentBridgeError.invalidAgentProtocol
    }
    return [.text(text)]
  }

}

/// Converts Host-verified private artifacts into the narrow content result of
/// Pi's `request_context` tool. It verifies every digest again at the remote
/// boundary and never exposes artifact paths or TCC handles to the child.
public enum AgentContextPayloadBuilder {
  public static func build(
    capsule: TaskCapsule,
    manifest: ContextManifest,
    artifactReader: any ContextArtifactReading,
    maximumContextBytes: Int = 12 * 1_024 * 1_024,
    now: Date = Date()
  ) async throws -> [ACPContentBlock] {
    guard capsule.id == manifest.taskID,
      capsule.targetLeaseID == manifest.targetLeaseID,
      capsule.contextManifestID == manifest.id
    else {
      throw PiAgentBridgeError.inconsistentTask
    }
    try capsule.validate(now: now)
    try manifest.validate(now: now)
    guard manifest.remoteTransmissionAllowed else {
      throw PiAgentBridgeError.contextTransmissionDenied
    }

    struct ManifestSummary: Encodable {
      let requestedScope: String
      let resolvedScope: String
      let omittedScopes: [String: String]
      let coherent: Bool
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let summaryData = try encoder.encode(
      ManifestSummary(
        requestedScope: manifest.requestedScope.rawValue,
        resolvedScope: manifest.resolvedScope.rawValue,
        omittedScopes: Dictionary(
          uniqueKeysWithValues: manifest.omittedScopes.map { ($0.key.rawValue, $0.value) }
        ),
        coherent: manifest.coherent
      )
    )
    guard let summary = String(data: summaryData, encoding: .utf8) else {
      throw PiAgentBridgeError.invalidAgentProtocol
    }
    var blocks: [ACPContentBlock] = [
      .text("Host-verified context manifest: \(summary)")
    ]
    var totalBytes = 0
    for artifact in manifest.artifacts {
      guard artifact.sensitivity <= .userContent else {
        throw PiAgentBridgeError.contextTransmissionDenied
      }
      guard
        let data = try? await artifactReader.readArtifact(
          id: artifact.id,
          taskID: capsule.id,
          targetLeaseID: capsule.targetLeaseID,
          now: now
        )
      else {
        throw PiAgentBridgeError.artifactUnavailable
      }
      let digest = SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
      guard digest == artifact.contentDigest.lowercased() else {
        throw PiAgentBridgeError.artifactDigestMismatch
      }
      totalBytes += data.count
      guard totalBytes <= maximumContextBytes else {
        throw PiAgentBridgeError.contextBudgetExceeded
      }
      if artifact.mediaType == "image/png" || artifact.mediaType == "image/jpeg" {
        blocks.append(.image(data: data.base64EncodedString(), mimeType: artifact.mediaType))
      } else if ["text/plain", "text/markdown", "application/json"].contains(
        artifact.mediaType
      ), let text = String(data: data, encoding: .utf8) {
        blocks.append(
          .text(
            """
            <untrusted-context artifact="\(artifact.id.uuidString)" scope="\(artifact.scope.rawValue)" media-type="\(artifact.mediaType)">
            \(text)
            </untrusted-context>
            """
          ))
      } else {
        throw PiAgentBridgeError.unsupportedArtifact
      }
    }
    return blocks
  }
}
