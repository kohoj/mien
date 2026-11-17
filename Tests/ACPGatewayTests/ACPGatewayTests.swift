import ACPGateway
import CryptoKit
import Foundation
import MienContracts
import XCTest

final class ACPGatewayTests: XCTestCase {
  func testInitializeRequestUsesStableProtocolV1AndNoHostFilesystemTools() throws {
    let request = JSONRPCRequest(
      id: 1,
      method: "initialize",
      params: ACPInitializeParameters(
        clientCapabilities: ACPClientCapabilities(),
        clientInfo: ACPImplementation(
          name: "mien",
          title: "Mien",
          version: "0.1.0"
        )
      )
    )
    let data = try NDJSONRPCCodec().encode(request)
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertTrue(text.hasSuffix("\n"))
    XCTAssertTrue(text.contains("\"protocolVersion\":1"))
    XCTAssertTrue(text.contains("\"readTextFile\":false"))
    XCTAssertTrue(text.contains("\"writeTextFile\":false"))
    XCTAssertTrue(text.contains("\"terminal\":false"))
  }

  func testConfigurationRejectsShellLaunchAndSensitiveAppServerLogs() {
    XCTAssertThrowsError(
      try ACPProcessSupervisor(
        configuration: ACPProcessConfiguration(
          executableURL: URL(fileURLWithPath: "/usr/bin/npx"),
          workingDirectoryURL: URL(fileURLWithPath: "/tmp/task")
        ))
    ) { error in
      XCTAssertEqual(error as? ACPConfigurationError, .shellLauncherForbidden)
    }

    XCTAssertThrowsError(
      try ACPProcessSupervisor(
        configuration: ACPProcessConfiguration(
          executableURL: URL(
            fileURLWithPath: "/Applications/Product.app/Contents/Helpers/mien-pi-agent"),
          workingDirectoryURL: URL(fileURLWithPath: "/tmp/task"),
          environment: ["APP_SERVER_LOGS": "/tmp/private"]
        ))
    ) { error in
      XCTAssertEqual(error as? ACPConfigurationError, .sensitiveLoggingForbidden)
    }

    XCTAssertThrowsError(
      try ACPProcessSupervisor(
        configuration: ACPProcessConfiguration(
          executableURL: URL(
            fileURLWithPath: "/Applications/Product.app/Contents/Helpers/mien-pi-agent"),
          workingDirectoryURL: URL(fileURLWithPath: "/tmp/task"),
          expectedExecutableSHA256: "not-a-digest"
        )
      )
    ) { error in
      XCTAssertEqual(error as? ACPConfigurationError, .invalidExecutableDigest)
    }
  }

  func testExecutableIntegrityRejectsRuntimeSubstitution() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let data = Data("runtime".utf8)
    XCTAssertTrue(
      FileManager.default.createFile(
        atPath: url.path,
        contents: data,
        attributes: [.posixPermissions: 0o700]
      ))
    let digest = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()

    XCTAssertNoThrow(try ExecutableIntegrity.verify(url, expectedSHA256: digest))
    XCTAssertThrowsError(
      try ExecutableIntegrity.verify(
        url,
        expectedSHA256: String(repeating: "0", count: 64)
      )
    ) { error in
      XCTAssertEqual(error as? ExecutableIntegrityError, .digestMismatch)
    }
  }

  func testSupervisorNegotiatesBeforeReadyAndCircuitBreaksRestarts() async throws {
    let configuration = ACPProcessConfiguration(
      executableURL: URL(
        fileURLWithPath: "/Applications/Product.app/Contents/Helpers/mien-pi-agent"),
      workingDirectoryURL: URL(fileURLWithPath: "/tmp/task"),
      maximumRestartsPerMinute: 2
    )
    let supervisor = try ACPProcessSupervisor(configuration: configuration)
    let now = Date()

    try await supervisor.beginStart(now: now)
    try await supervisor.processDidLaunch()
    try await supervisor.handshakeSucceeded(protocolVersion: 1)
    let readyState = await supervisor.state
    XCTAssertEqual(readyState, .ready(protocolVersion: 1))

    await supervisor.processDidCrash(now: now)
    guard case .backoff(let until) = await supervisor.state else {
      return XCTFail("Expected backoff")
    }
    try await supervisor.beginStart(now: until)
    await supervisor.processDidCrash(now: until)
    let failedState = await supervisor.state
    guard case .failed(let reason) = failedState else {
      return XCTFail("Expected restart circuit breaker")
    }
    XCTAssertEqual(reason, "restart circuit breaker opened")
  }

  func testConnectionCorrelatesResponsesAndDeniesUnbrokeredPermission() async throws {
    let transport = LoopbackTransport()
    let connection = ACPConnection(transport: transport)
    try await connection.start()

    let value = try await connection.request(
      method: "test/echo",
      parameters: ["message": "hello"]
    )
    XCTAssertEqual(value, .object(["accepted": .bool(true)]))

    transport.sendPermissionRequest()
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !transport.containsCancelledPermissionResponse, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertTrue(transport.containsCancelledPermissionResponse)
    await connection.close()
  }

  func testConnectionRoutesOnlyRegisteredChildRequestsAndReturnsTypedResult() async throws {
    let transport = LoopbackTransport()
    let connection = ACPConnection(
      transport: transport,
      inboundRequestHandler: { message in
        guard message.method == "mien/request_context" else {
          throw ACPConnectionError.invalidResult
        }
        return .object(["accepted": .bool(true)])
      }
    )
    try await connection.start()

    transport.sendContextRequest()
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !transport.containsAcceptedContextResponse, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }

    XCTAssertTrue(transport.containsAcceptedContextResponse)
    await connection.close()
  }

  func testConnectionSendsStableSessionCancellationNotification() async throws {
    let transport = LoopbackTransport()
    let connection = ACPConnection(transport: transport)
    try await connection.start()

    try await connection.notify(
      method: "session/cancel",
      parameters: ACPCancelParameters(sessionId: "session-1")
    )

    XCTAssertTrue(transport.containsSessionCancelNotification(sessionID: "session-1"))
    await connection.close()
  }

  func testConnectionTimeoutIdentifiesTheStalledMethod() async throws {
    let transport = LoopbackTransport()
    let connection = ACPConnection(transport: transport)
    try await connection.start()

    do {
      _ = try await connection.request(
        method: "session/prompt",
        parameters: ["message": "fixture"],
        timeout: .milliseconds(1)
      )
      XCTFail("Expected timeout")
    } catch {
      XCTAssertEqual(
        error as? ACPConnectionError,
        .requestTimedOut(method: "session/prompt")
      )
    }
    await connection.close()
  }

  func testPromptContentUsesStableV1Discriminators() throws {
    let request = JSONRPCRequest(
      id: 7,
      method: "session/prompt",
      params: ACPPromptParameters(
        sessionId: "session-1",
        prompt: [
          .text("Summarize this"),
          .resourceLink(
            name: "context",
            uri: "mien://artifact/1",
            mimeType: "text/plain"
          ),
        ]
      )
    )
    let text = try XCTUnwrap(
      String(
        data: NDJSONRPCCodec().encode(request),
        encoding: .utf8
      ))

    XCTAssertTrue(text.contains("\"method\":\"session/prompt\""))
    XCTAssertTrue(text.contains("\"type\":\"text\""))
    XCTAssertTrue(text.contains("\"type\":\"resource_link\""))
  }

  func testActivityProjectionNeverExposesThoughtContent() throws {
    let message = try NDJSONRPCCodec().decode(
      Data(
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_thought_chunk","messageId":"thought-7","content":{"type":"text","text":"private reasoning must not appear"}}}}"#
          .utf8
      )
    )

    let activity = try XCTUnwrap(ACPAgentActivityUpdate.project(message).only)

    XCTAssertEqual(activity.id, "thought:thought-7")
    XCTAssertEqual(activity.kind, .thinking)
    XCTAssertEqual(activity.status, .active)
    XCTAssertNil(activity.title)
  }

  func testActivityProjectionUsesTypedToolIdentityAndStatusOnly() throws {
    let message = try NDJSONRPCCodec().decode(
      Data(
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-42","title":"Read current conversation","status":"completed","rawInput":{"secret":"never project"},"rawOutput":"never project"}}}"#
          .utf8
      )
    )

    let activity = try XCTUnwrap(ACPAgentActivityUpdate.project(message).only)

    XCTAssertEqual(activity.id, "tool:call-42")
    XCTAssertEqual(activity.kind, .tool)
    XCTAssertNil(activity.toolName)
    XCTAssertEqual(activity.title, "Read current conversation")
    XCTAssertEqual(activity.status, .completed)
  }

  func testActivityProjectionPreservesExactToolNameWithoutRawArguments() throws {
    let message = try NDJSONRPCCodec().decode(
      Data(
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"tool_call","toolCallId":"call-9","name":"request_context","title":"request_context(scope: conversation, evidence: [accessibility])","status":"in_progress","rawInput":{"content":"never project"}}}}"#
          .utf8
      )
    )

    let activity = try XCTUnwrap(ACPAgentActivityUpdate.project(message).only)

    XCTAssertEqual(activity.toolName, "request_context")
    XCTAssertEqual(
      activity.title,
      "request_context(scope: conversation, evidence: [accessibility])"
    )
    XCTAssertEqual(activity.status, .active)
  }

  func testThoughtLifecycleCanCompleteWithoutExposingThoughtContent() throws {
    let message = try NDJSONRPCCodec().decode(
      Data(
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"agent_thought_chunk","messageId":"thinking","content":{"type":"text","text":"private reasoning"},"status":"completed"}}}"#
          .utf8
      )
    )

    let activity = try XCTUnwrap(ACPAgentActivityUpdate.project(message).only)

    XCTAssertEqual(activity.id, "thought:thinking")
    XCTAssertNil(activity.title)
    XCTAssertEqual(activity.status, .completed)
  }

  func testActivityProjectionMapsPlanEntriesWithoutInventingProgress() throws {
    let message = try NDJSONRPCCodec().decode(
      Data(
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"plan","entries":[{"content":"Inspect evidence","status":"completed"},{"content":"Compose answer","status":"pending"}]}}}"#
          .utf8
      )
    )

    let activities = ACPAgentActivityUpdate.project(message)

    XCTAssertEqual(activities.map(\.id), ["plan:0", "plan:1"])
    XCTAssertEqual(activities.map(\.status), [.completed, .active])
    XCTAssertEqual(activities.map(\.title), ["Inspect evidence", "Compose answer"])
  }

  func testSessionModelCatalogComesOnlyFromTypedACPConfiguration() throws {
    let data = Data(
      #"""
      {"sessionId":"session-1","configOptions":[
        {"id":"mode","name":"Mode","type":"select","category":"mode","currentValue":"default","options":[]},
        {"id":"model","name":"Model","description":"Session model","category":"model","type":"select","currentValue":"gpt-primary","options":[
          {"value":"gpt-primary","name":"Primary","description":"Deep work"},
          {"value":"gpt-fast","name":"Fast","description":null}
        ]}
      ]}
      """#.utf8
    )
    let result = try JSONDecoder().decode(ACPNewSessionResult.self, from: data)

    let configuration = try result.agentModelConfiguration()

    XCTAssertEqual(configuration.configID, "model")
    XCTAssertEqual(configuration.catalog.currentModelID, "gpt-primary")
    XCTAssertEqual(
      configuration.catalog.options,
      [
        AgentModelOption(id: "gpt-primary", name: "Primary", description: "Deep work"),
        AgentModelOption(id: "gpt-fast", name: "Fast"),
      ]
    )
  }

  func testMalformedOrMissingModelConfigurationFailsClosed() throws {
    let missing = try JSONDecoder().decode(
      ACPNewSessionResult.self,
      from: Data(#"{"sessionId":"session-1"}"#.utf8)
    )
    XCTAssertThrowsError(try missing.agentModelConfiguration()) { error in
      XCTAssertEqual(error as? ACPModelConfigurationError, .unavailable)
    }

    let malformed = try JSONDecoder().decode(
      ACPNewSessionResult.self,
      from: Data(
        #"""
        {"sessionId":"session-1","configOptions":[
          {"id":"model","name":"Model","category":"model","type":"select","currentValue":"missing","options":[
            {"value":"present","name":"Present"}
          ]}
        ]}
        """#.utf8
      )
    )
    XCTAssertThrowsError(try malformed.agentModelConfiguration()) { error in
      XCTAssertEqual(error as? ACPModelConfigurationError, .malformed)
    }
  }

  func testModelSelectionUsesStandardACPConfigMethodAndValueID() throws {
    let request = JSONRPCRequest(
      id: 8,
      method: "session/set_config_option",
      params: ACPSetSessionConfigOptionParameters(
        sessionId: "session-1",
        configId: "model",
        value: "gpt-primary"
      )
    )
    let text = try XCTUnwrap(
      String(data: NDJSONRPCCodec().encode(request), encoding: .utf8)
    )

    XCTAssertTrue(text.contains("\"method\":\"session/set_config_option\""))
    XCTAssertTrue(text.contains("\"configId\":\"model\""))
    XCTAssertTrue(text.contains("\"value\":\"gpt-primary\""))
    XCTAssertFalse(text.contains("set_model"))
  }

  func testLivePiAgentHandshakeWhenExplicitlyEnabled() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RUN_PI_AGENT_LIVE_SMOKE"] == "1" else {
      throw XCTSkip("set RUN_PI_AGENT_LIVE_SMOKE=1 to exercise the pinned Pi runtime")
    }
    let executable = try XCTUnwrap(environment["PI_AGENT_EXECUTABLE"])
    let agentDirectory = try XCTUnwrap(environment["PI_AGENT_DIR"])
    let runtime = try ACPClientRuntime(
      configuration: ACPProcessConfiguration(
        executableURL: URL(fileURLWithPath: executable),
        workingDirectoryURL: FileManager.default.temporaryDirectory,
        environment: [
          "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
          "PI_AGENT_DIR": agentDirectory,
        ]
      ),
      clientInfo: ACPImplementation(
        name: "mien-tests",
        title: "Mien Tests",
        version: "0.1.0"
      )
    )

    let result = try await runtime.start()
    XCTAssertEqual(result.protocolVersion, ACPProtocolV1.version)
    await runtime.stop()
  }
}

extension Array {
  fileprivate var only: Element? { count == 1 ? self[0] : nil }
}

private final class LoopbackTransport: ACPWireTransport, @unchecked Sendable {
  let messages: AsyncThrowingStream<Data, Error>

  private let continuation: AsyncThrowingStream<Data, Error>.Continuation
  private let lock = NSLock()
  private var responses: [Data] = []
  private var started = false

  init() {
    var captured: AsyncThrowingStream<Data, Error>.Continuation?
    messages = AsyncThrowingStream { captured = $0 }
    continuation = captured!
  }

  func start() throws {
    lock.lock()
    defer { lock.unlock() }
    started = true
  }

  func send(_ data: Data) throws {
    lock.lock()
    responses.append(data)
    lock.unlock()

    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let method = object["method"] as? String,
      method == "test/echo",
      let id = object["id"] as? Int64
    else {
      return
    }
    let response: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id,
      "result": ["accepted": true],
    ]
    continuation.yield(try JSONSerialization.data(withJSONObject: response))
  }

  func stop() async {
    continuation.finish()
  }

  func sendPermissionRequest() {
    let request: [String: Any] = [
      "jsonrpc": "2.0",
      "id": 99,
      "method": "session/request_permission",
      "params": [
        "sessionId": "session-1",
        "toolCall": ["toolCallId": "tool-1"],
        "options": [],
      ],
    ]
    continuation.yield(try! JSONSerialization.data(withJSONObject: request))
  }

  func sendContextRequest() {
    let request: [String: Any] = [
      "jsonrpc": "2.0",
      "id": 100,
      "method": "mien/request_context",
      "params": ["sessionId": "session-1"],
    ]
    continuation.yield(try! JSONSerialization.data(withJSONObject: request))
  }

  var containsCancelledPermissionResponse: Bool {
    lock.lock()
    defer { lock.unlock() }
    return responses.contains { data in
      guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["id"] as? Int == 99,
        let result = object["result"] as? [String: Any],
        let outcome = result["outcome"] as? [String: Any]
      else {
        return false
      }
      return outcome["outcome"] as? String == "cancelled"
    }
  }

  var containsAcceptedContextResponse: Bool {
    lock.lock()
    defer { lock.unlock() }
    return responses.contains { data in
      guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["id"] as? Int == 100,
        let result = object["result"] as? [String: Any]
      else {
        return false
      }
      return result["accepted"] as? Bool == true
    }
  }

  func containsSessionCancelNotification(sessionID: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return responses.contains { data in
      guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["method"] as? String == "session/cancel",
        object["id"] == nil,
        let parameters = object["params"] as? [String: Any]
      else {
        return false
      }
      return parameters["sessionId"] as? String == sessionID
    }
  }
}
