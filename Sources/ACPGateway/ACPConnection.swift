import Foundation
import SubprocessKernel

public enum ACPTransportError: Error, Equatable, Sendable {
  case alreadyStarted
  case notStarted
  case executableUnavailable
  case processExited(status: Int32)
  case lineTooLarge
  case writeFailed
  case closed
  case executableIntegrityMismatch
}

public protocol ACPWireTransport: Sendable {
  var messages: AsyncThrowingStream<Data, Error> { get }
  func start() throws
  func send(_ data: Data) throws
  func stop() async
}

public final class ACPSubprocessTransport: ACPWireTransport, @unchecked Sendable {
  private struct State {
    var process: ManagedSubprocess?
    var standardInput: FileHandle?
    var lineBuffer = Data()
    var started = false
    var stopping = false
    var finished = false
  }

  public let messages: AsyncThrowingStream<Data, Error>

  private let configuration: ACPProcessConfiguration
  private let maximumLineBytes: Int
  private let lock = NSLock()
  private var state = State()
  private let continuation: AsyncThrowingStream<Data, Error>.Continuation

  public init(
    configuration: ACPProcessConfiguration,
    maximumLineBytes: Int = 24 * 1_024 * 1_024
  ) throws {
    try configuration.validate()
    self.configuration = configuration
    self.maximumLineBytes = max(64 * 1_024, maximumLineBytes)
    var captured: AsyncThrowingStream<Data, Error>.Continuation?
    messages = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(512)) { captured = $0 }
    continuation = captured!
  }

  public func start() throws {
    guard FileManager.default.isExecutableFile(atPath: configuration.executableURL.path) else {
      throw ACPTransportError.executableUnavailable
    }
    if let expected = configuration.expectedExecutableSHA256 {
      do {
        try ExecutableIntegrity.verify(
          configuration.executableURL,
          expectedSHA256: expected
        )
      } catch {
        throw ACPTransportError.executableIntegrityMismatch
      }
    }

    lock.lock()
    guard !state.started else {
      lock.unlock()
      throw ACPTransportError.alreadyStarted
    }
    state.started = true
    lock.unlock()

    let process = try ManagedSubprocess.launch(
      executable: configuration.executableURL,
      arguments: configuration.arguments,
      environment: configuration.sanitizedEnvironment,
      workingDirectory: configuration.workingDirectoryURL
    )
    process.standardOutput.readabilityHandler = { [weak self] handle in
      guard let self else { return }
      let data = handle.availableData
      if !data.isEmpty { self.ingest(data) }
    }
    process.standardError.readabilityHandler = { handle in
      _ = handle.availableData
    }

    lock.lock()
    state.process = process
    state.standardInput = process.standardInput
    lock.unlock()

    Task.detached { [weak self] in
      do {
        let exit = try process.wait()
        self?.finish(status: exit.exitCode)
      } catch {
        self?.finish(status: -1)
      }
    }
  }

  public func send(_ data: Data) throws {
    lock.lock()
    guard state.started, !state.finished, let input = state.standardInput else {
      lock.unlock()
      throw ACPTransportError.closed
    }
    lock.unlock()
    guard data.count <= maximumLineBytes + 1 else {
      throw ACPTransportError.lineTooLarge
    }
    do {
      try input.write(contentsOf: data)
    } catch {
      throw ACPTransportError.writeFailed
    }
  }

  public func stop() async {
    let resources = lock.withLock { () -> (ManagedSubprocess?, FileHandle?)? in
      guard !state.finished else { return nil }
      state.stopping = true
      let resources = (state.process, state.standardInput)
      state.standardInput = nil
      return resources
    }
    guard let (process, input) = resources else { return }

    try? input?.close()
    await process?.terminateAndWait(grace: .seconds(2))
  }

  private func ingest(_ data: Data) {
    lock.lock()
    guard !state.finished else {
      lock.unlock()
      return
    }
    state.lineBuffer.append(data)
    var lines: [Data] = []
    var oversized = false
    while let newline = state.lineBuffer.firstIndex(of: 0x0A) {
      if newline > maximumLineBytes {
        oversized = true
        break
      }
      var line = Data(state.lineBuffer[..<newline])
      state.lineBuffer.removeSubrange(...newline)
      if line.last == 0x0D { line.removeLast() }
      if !line.isEmpty { lines.append(line) }
    }
    if state.lineBuffer.count > maximumLineBytes { oversized = true }
    lock.unlock()
    if oversized {
      terminate(throwing: ACPTransportError.lineTooLarge)
      return
    }
    for line in lines {
      if case .dropped = continuation.yield(line) {
        terminate(throwing: ACPTransportError.lineTooLarge)
        return
      }
    }
  }

  private func terminate(throwing error: Error) {
    lock.lock()
    guard !state.finished else {
      lock.unlock()
      return
    }
    state.stopping = true
    state.finished = true
    let process = state.process
    let input = state.standardInput
    state.standardInput = nil
    state.process = nil
    lock.unlock()
    try? input?.close()
    process?.standardOutput.readabilityHandler = nil
    process?.standardError.readabilityHandler = nil
    process?.terminate(grace: .seconds(2))
    continuation.finish(throwing: error)
  }

  private func finish(status: Int32) {
    lock.lock()
    guard !state.finished else {
      lock.unlock()
      return
    }
    state.finished = true
    let stopping = state.stopping
    let trailing = state.lineBuffer
    let process = state.process
    state.lineBuffer.removeAll(keepingCapacity: false)
    state.standardInput = nil
    state.process = nil
    lock.unlock()

    process?.standardOutput.readabilityHandler = nil
    process?.standardError.readabilityHandler = nil

    if !trailing.isEmpty { continuation.yield(trailing) }
    if stopping || status == 0 {
      continuation.finish()
    } else {
      continuation.finish(throwing: ACPTransportError.processExited(status: status))
    }
  }

}

public enum ACPConnectionError: Error, Equatable, Sendable {
  case notStarted
  case alreadyStarted
  case closed
  case responseMissingResult
  case remoteError(code: Int, message: String)
  case invalidResult
  case unsupportedContent
  case agentOutputTooLarge
  case requestTimedOut(method: String)
}

/// Handles the deliberately narrow set of child-to-Host requests owned by the
/// embedding product. The ACP transport remains generic and denies every
/// unregistered request fail-closed.
public typealias ACPInboundRequestHandler =
  @Sendable (JSONRPCIncomingMessage) async throws -> JSONValue

public actor ACPConnection {
  private struct AgentMessageProjection {
    var messageID: String?
    var text: String
  }

  private let transport: any ACPWireTransport
  private let inboundRequestHandler: ACPInboundRequestHandler?
  private let codec = NDJSONRPCCodec()
  private var nextRequestID: Int64 = 1
  private var pending: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
  private var readerTask: Task<Void, Never>?
  private var started = false
  private var closed = false
  private var agentMessageBySession: [String: AgentMessageProjection] = [:]
  private let updateContinuation: AsyncStream<JSONRPCIncomingMessage>.Continuation
  private var activityContinuations:
    [UUID: (sessionID: String, continuation: AsyncStream<ACPAgentActivityUpdate>.Continuation)] =
      [:]

  public nonisolated let updates: AsyncStream<JSONRPCIncomingMessage>

  public init(
    transport: any ACPWireTransport,
    inboundRequestHandler: ACPInboundRequestHandler? = nil
  ) {
    self.transport = transport
    self.inboundRequestHandler = inboundRequestHandler
    var captured: AsyncStream<JSONRPCIncomingMessage>.Continuation?
    updates = AsyncStream(bufferingPolicy: .bufferingNewest(128)) { captured = $0 }
    updateContinuation = captured!
  }

  public func start() throws {
    guard !started else { throw ACPConnectionError.alreadyStarted }
    try transport.start()
    started = true
    readerTask = Task { await consumeMessages() }
  }

  public func request<Parameters: Encodable & Sendable>(
    method: String,
    parameters: Parameters,
    timeout: Duration = .seconds(30)
  ) async throws -> JSONValue {
    guard started, !closed else { throw ACPConnectionError.notStarted }
    let requestID = nextRequestID
    nextRequestID &+= 1
    let data = try codec.encode(
      JSONRPCRequest(id: requestID, method: method, params: parameters)
    )

    return try await withThrowingTaskGroup(of: JSONValue.self) { group in
      group.addTask {
        try await self.awaitResponse(requestID: requestID, data: data)
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw ACPConnectionError.requestTimedOut(method: method)
      }
      defer { group.cancelAll() }
      guard let first = try await group.next() else {
        throw ACPConnectionError.requestTimedOut(method: method)
      }
      return first
    }
  }

  private func awaitResponse(requestID: Int64, data: Data) async throws -> JSONValue {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending[requestID] = continuation
        do {
          try transport.send(data)
        } catch {
          pending.removeValue(forKey: requestID)
          continuation.resume(throwing: error)
        }
      }
    } onCancel: {
      Task { await self.cancelPendingRequest(id: requestID) }
    }
  }

  public func notify<Parameters: Encodable & Sendable>(
    method: String,
    parameters: Parameters
  ) throws {
    guard started, !closed else { throw ACPConnectionError.notStarted }
    try transport.send(codec.encode(JSONRPCNotification(method: method, params: parameters)))
  }

  public func close() async {
    guard !closed else { return }
    closed = true
    readerTask?.cancel()
    readerTask = nil
    failPending(with: ACPConnectionError.closed)
    updateContinuation.finish()
    finishActivityStreams()
    await transport.stop()
  }

  public func activityUpdates(sessionID: String) -> AsyncStream<ACPAgentActivityUpdate> {
    let subscriptionID = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(128)) { continuation in
      activityContinuations[subscriptionID] = (sessionID, continuation)
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeActivityContinuation(id: subscriptionID) }
      }
    }
  }

  public func takeAgentText(sessionID: String) -> String {
    agentMessageBySession.removeValue(forKey: sessionID)?.text ?? ""
  }

  public func discardAgentText(sessionID: String) {
    agentMessageBySession.removeValue(forKey: sessionID)
  }

  private func consumeMessages() async {
    do {
      for try await line in transport.messages {
        try Task.checkCancellation()
        let message = try codec.decode(line)
        await handle(message)
      }
      await connectionEnded(with: ACPConnectionError.closed)
    } catch is CancellationError {
      return
    } catch {
      await connectionEnded(with: error)
    }
  }

  private func handle(_ message: JSONRPCIncomingMessage) async {
    if let method = message.method {
      if let id = message.id {
        await handleInboundRequest(message, id: id, method: method)
      } else {
        do {
          try projectAgentText(from: message)
        } catch {
          await connectionEnded(with: error)
          return
        }
        let projectedActivities = ACPAgentActivityUpdate.project(message)
        if !projectedActivities.isEmpty {
          for activity in projectedActivities {
            for subscription in activityContinuations.values
            where subscription.sessionID == activity.sessionID {
              subscription.continuation.yield(activity)
            }
          }
        }
        updateContinuation.yield(message)
      }
      return
    }

    if let id = message.id, let continuation = pending.removeValue(forKey: id) {
      if let error = message.error {
        continuation.resume(
          throwing: ACPConnectionError.remoteError(
            code: error.code,
            message: error.message
          )
        )
      } else if let result = message.result {
        continuation.resume(returning: result)
      } else {
        continuation.resume(throwing: ACPConnectionError.responseMissingResult)
      }
      return
    }
    updateContinuation.yield(message)
  }

  private func handleInboundRequest(
    _ message: JSONRPCIncomingMessage,
    id: Int64,
    method: String
  ) async {
    if let inboundRequestHandler {
      do {
        let result = try await inboundRequestHandler(message)
        try transport.send(codec.encode(JSONRPCResponse(id: id, result: result)))
        return
      } catch {
        do {
          try transport.send(
            codec.encode(
              JSONRPCErrorResponse(
                id: id,
                code: -32001,
                message: "Host rejected the Agent request"
              )))
        } catch {
          await connectionEnded(with: error)
        }
        return
      }
    }
    await denyInboundRequest(id: id, method: method)
  }

  private func projectAgentText(from message: JSONRPCIncomingMessage) throws {
    guard message.method == "session/update",
      case .object(let parameters)? = message.params,
      case .string(let sessionID)? = parameters["sessionId"],
      case .object(let update)? = parameters["update"],
      case .string(let kind)? = update["sessionUpdate"],
      kind == "agent_message_chunk",
      case .object(let content)? = update["content"],
      case .string(let type)? = content["type"],
      type == "text",
      case .string(let text)? = content["text"]
    else {
      return
    }
    let messageID: String?
    if case .string(let identifier)? = update["messageId"] {
      messageID = identifier
    } else {
      messageID = nil
    }
    if let current = agentMessageBySession[sessionID],
      let messageID,
      current.messageID != messageID
    {
      agentMessageBySession[sessionID] = AgentMessageProjection(
        messageID: messageID,
        text: text
      )
    } else {
      var current =
        agentMessageBySession[sessionID]
        ?? AgentMessageProjection(messageID: messageID, text: "")
      current.text.append(text)
      guard current.text.utf8.count <= 1_048_576 else {
        throw ACPConnectionError.agentOutputTooLarge
      }
      agentMessageBySession[sessionID] = current
    }
  }

  private func denyInboundRequest(id: Int64, method: String) async {
    do {
      if method == "session/request_permission" {
        let result: JSONValue = .object([
          "outcome": .object(["outcome": .string("cancelled")])
        ])
        try transport.send(codec.encode(JSONRPCResponse(id: id, result: result)))
      } else {
        try transport.send(
          codec.encode(
            JSONRPCErrorResponse(
              id: id,
              code: -32601,
              message: "method not available at this trust boundary"
            )))
      }
    } catch {
      await connectionEnded(with: error)
    }
  }

  private func cancelPendingRequest(id: Int64) {
    pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }

  private func connectionEnded(with error: Error) async {
    guard !closed else { return }
    closed = true
    failPending(with: error)
    updateContinuation.finish()
    finishActivityStreams()
    await transport.stop()
  }

  private func removeActivityContinuation(id: UUID) {
    activityContinuations.removeValue(forKey: id)
  }

  private func finishActivityStreams() {
    let continuations = activityContinuations.values.map(\.continuation)
    activityContinuations.removeAll()
    for continuation in continuations { continuation.finish() }
  }

  private func failPending(with error: Error) {
    let continuations = pending.values
    pending.removeAll()
    for continuation in continuations {
      continuation.resume(throwing: error)
    }
  }
}
