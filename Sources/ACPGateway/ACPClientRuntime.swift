import Foundation

public enum ACPContentBlock: Codable, Equatable, Sendable {
  case text(String)
  case image(data: String, mimeType: String)
  case resourceLink(name: String, uri: String, mimeType: String?)

  private enum CodingKeys: String, CodingKey {
    case type
    case text
    case data
    case name
    case uri
    case mimeType
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .type) {
    case "text":
      self = .text(try container.decode(String.self, forKey: .text))
    case "image":
      self = .image(
        data: try container.decode(String.self, forKey: .data),
        mimeType: try container.decode(String.self, forKey: .mimeType)
      )
    case "resource_link":
      self = .resourceLink(
        name: try container.decode(String.self, forKey: .name),
        uri: try container.decode(String.self, forKey: .uri),
        mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType)
      )
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "unsupported ACP content block"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let text):
      try container.encode("text", forKey: .type)
      try container.encode(text, forKey: .text)
    case .image(let data, let mimeType):
      try container.encode("image", forKey: .type)
      try container.encode(data, forKey: .data)
      try container.encode(mimeType, forKey: .mimeType)
    case .resourceLink(let name, let uri, let mimeType):
      try container.encode("resource_link", forKey: .type)
      try container.encode(name, forKey: .name)
      try container.encode(uri, forKey: .uri)
      try container.encodeIfPresent(mimeType, forKey: .mimeType)
    }
  }
}

public struct ACPPromptParameters: Codable, Equatable, Sendable {
  public let sessionId: String
  public let prompt: [ACPContentBlock]

  public init(sessionId: String, prompt: [ACPContentBlock]) {
    self.sessionId = sessionId
    self.prompt = prompt
  }
}

public struct ACPCancelParameters: Codable, Equatable, Sendable {
  public let sessionId: String

  public init(sessionId: String) {
    self.sessionId = sessionId
  }
}

public struct ACPCloseSessionParameters: Codable, Equatable, Sendable {
  public let sessionId: String

  public init(sessionId: String) {
    self.sessionId = sessionId
  }
}

public enum ACPStopReason: String, Codable, Equatable, Sendable {
  case endTurn = "end_turn"
  case maxTokens = "max_tokens"
  case maxTurnRequests = "max_turn_requests"
  case refusal
  case cancelled
}

public struct ACPPromptResult: Codable, Equatable, Sendable {
  public let stopReason: ACPStopReason
}

public struct ACPAgentTurnResult: Equatable, Sendable {
  public let stopReason: ACPStopReason
  public let text: String

  public init(stopReason: ACPStopReason, text: String) {
    self.stopReason = stopReason
    self.text = text
  }
}

public actor ACPClientRuntime {
  private let supervisor: ACPProcessSupervisor
  private let connection: ACPConnection
  private let clientInfo: ACPImplementation
  private let negotiationPolicy = ACPNegotiationPolicy()
  private var initializeResult: ACPInitializeResult?

  public init(
    configuration: ACPProcessConfiguration,
    clientInfo: ACPImplementation
  ) throws {
    supervisor = try ACPProcessSupervisor(configuration: configuration)
    connection = ACPConnection(
      transport: try ACPSubprocessTransport(configuration: configuration)
    )
    self.clientInfo = clientInfo
  }

  public func start(now: Date = Date()) async throws -> ACPInitializeResult {
    try await supervisor.beginStart(now: now)
    do {
      try await connection.start()
      try await supervisor.processDidLaunch()
      let value = try await connection.request(
        method: "initialize",
        parameters: ACPInitializeParameters(
          clientCapabilities: ACPClientCapabilities(),
          clientInfo: clientInfo
        ),
        timeout: .seconds(15)
      )
      let result: ACPInitializeResult = try Self.decode(value)
      try negotiationPolicy.validate(result)
      try await supervisor.handshakeSucceeded(protocolVersion: result.protocolVersion)
      initializeResult = result
      return result
    } catch {
      await connection.close()
      await supervisor.processDidCrash(now: now)
      throw error
    }
  }

  public func newSession(
    workingDirectory: URL,
    mcpServers: [JSONValue] = []
  ) async throws -> ACPNewSessionResult {
    let parameters = ACPNewSessionParameters(
      cwd: workingDirectory.path,
      additionalDirectories: [],
      mcpServers: mcpServers
    )
    try parameters.validate()
    let value = try await connection.request(
      method: "session/new",
      parameters: parameters,
      // Cold Codex startup can include account and model discovery. Session creation is
      // not retried because the server may already have accepted it.
      timeout: .seconds(30)
    )
    return try Self.decode(value)
  }

  public func prompt(
    sessionID: String,
    content: [ACPContentBlock],
    timeout: Duration = .seconds(120)
  ) async throws -> ACPPromptResult {
    guard !sessionID.isEmpty, !content.isEmpty else {
      throw ACPConnectionError.invalidResult
    }
    if content.contains(where: \.isImage), initializeResult?.supportsImagePrompt != true {
      throw ACPConnectionError.unsupportedContent
    }
    return try await withTaskCancellationHandler {
      let value = try await connection.request(
        method: "session/prompt",
        parameters: ACPPromptParameters(sessionId: sessionID, prompt: content),
        timeout: timeout
      )
      return try Self.decode(value)
    } onCancel: {
      Task { try? await self.cancel(sessionID: sessionID) }
    }
  }

  public func cancel(sessionID: String) async throws {
    guard !sessionID.isEmpty else { throw ACPConnectionError.invalidResult }
    try await connection.notify(
      method: "session/cancel",
      parameters: ACPCancelParameters(sessionId: sessionID)
    )
  }

  public func closeSession(sessionID: String) async throws {
    guard !sessionID.isEmpty else { throw ACPConnectionError.invalidResult }
    _ = try await connection.request(
      method: "session/close",
      parameters: ACPCloseSessionParameters(sessionId: sessionID),
      timeout: .seconds(5)
    )
    await connection.discardAgentText(sessionID: sessionID)
  }

  public func promptCollectingText(
    sessionID: String,
    content: [ACPContentBlock],
    timeout: Duration = .seconds(120)
  ) async throws -> ACPAgentTurnResult {
    _ = await connection.takeAgentText(sessionID: sessionID)
    let result = try await prompt(sessionID: sessionID, content: content, timeout: timeout)
    let text = await connection.takeAgentText(sessionID: sessionID)
    return ACPAgentTurnResult(stopReason: result.stopReason, text: text)
  }

  public nonisolated var updates: AsyncStream<JSONRPCIncomingMessage> {
    connection.updates
  }

  public func stop() async {
    if case .ready = await supervisor.state {
      try? await supervisor.beginDrain()
    }
    await connection.close()
    await supervisor.processDidStop()
  }

  public var state: ACPProcessState {
    get async { await supervisor.state }
  }

  private static func decode<Value: Decodable>(_ value: JSONValue) throws -> Value {
    do {
      let data = try JSONEncoder().encode(value)
      return try JSONDecoder().decode(Value.self, from: data)
    } catch {
      throw ACPConnectionError.invalidResult
    }
  }
}

extension ACPContentBlock {
  fileprivate var isImage: Bool {
    if case .image = self { return true }
    return false
  }
}

extension ACPInitializeResult {
  fileprivate var supportsImagePrompt: Bool {
    guard case .object(let capabilities)? = agentCapabilities,
      case .object(let promptCapabilities)? = capabilities["promptCapabilities"],
      case .bool(let supported)? = promptCapabilities["image"]
    else {
      return false
    }
    return supported
  }
}
