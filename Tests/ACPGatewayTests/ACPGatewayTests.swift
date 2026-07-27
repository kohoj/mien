import ACPGateway
import CryptoKit
import Foundation
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
            fileURLWithPath: "/Applications/Product.app/Contents/Helpers/codex-acp"),
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
            fileURLWithPath: "/Applications/Product.app/Contents/Helpers/codex-acp"),
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
      executableURL: URL(fileURLWithPath: "/Applications/Product.app/Contents/Helpers/codex-acp"),
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

  func testLiveCodexACPHandshakeWhenExplicitlyEnabled() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RUN_ACP_LIVE_SMOKE"] == "1" else {
      throw XCTSkip("set RUN_ACP_LIVE_SMOKE=1 to exercise the pinned nested runtime")
    }
    let executable = try XCTUnwrap(environment["ACP_EXECUTABLE"])
    let codexPath = try XCTUnwrap(environment["ACP_CODEX_PATH"])
    let codexHomePath = try XCTUnwrap(environment["ACP_CODEX_HOME_PATH"])
    let runtime = try ACPClientRuntime(
      configuration: ACPProcessConfiguration(
        executableURL: URL(fileURLWithPath: executable),
        workingDirectoryURL: FileManager.default.temporaryDirectory,
        environment: [
          "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
          "CODEX_PATH": codexPath,
          "CODEX_HOME": codexHomePath,
          "NO_BROWSER": "1",
          "INITIAL_AGENT_MODE": "read-only",
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

  func testLiveCodexACPTurnWhenExplicitlyEnabled() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RUN_ACP_LIVE_PROMPT"] == "1" else {
      throw XCTSkip("set RUN_ACP_LIVE_PROMPT=1 to exercise a real Codex turn")
    }
    let executable = try XCTUnwrap(environment["ACP_EXECUTABLE"])
    let codexPath = try XCTUnwrap(environment["ACP_CODEX_PATH"])
    let codexHomePath = try XCTUnwrap(environment["ACP_CODEX_HOME_PATH"])
    let runtime = try ACPClientRuntime(
      configuration: ACPProcessConfiguration(
        executableURL: URL(fileURLWithPath: executable),
        workingDirectoryURL: FileManager.default.temporaryDirectory,
        environment: [
          "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
          "CODEX_PATH": codexPath,
          "CODEX_HOME": codexHomePath,
          "NO_BROWSER": "1",
          "INITIAL_AGENT_MODE": "read-only",
        ]
      ),
      clientInfo: ACPImplementation(
        name: "mien-tests",
        title: "Mien Tests",
        version: "0.1.0"
      )
    )

    _ = try await runtime.start()
    let session = try await runtime.newSession(
      workingDirectory: FileManager.default.temporaryDirectory
    )
    let result = try await runtime.promptCollectingText(
      sessionID: session.sessionId,
      content: [.text("Reply with exactly: READY")]
    )
    XCTAssertEqual(result.stopReason, .endTurn)
    XCTAssertEqual(result.text.trimmingCharacters(in: .whitespacesAndNewlines), "READY")
    await runtime.stop()
  }
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

  func stop() {
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
