import ACPGateway
import Foundation
import MienContracts
import XCTest

@testable import HostRuntime

final class PiAgentBridgeTests: XCTestCase {
  func testTypedNoContextDecisionCompletesWithoutCallingEvidenceAcquisition() async throws {
    let sessionID = UUID().uuidString
    let observations = ContextDecisionObservations()
    let exchange = AgentTurnExchange(
      sessionID: sessionID,
      catalog: [],
      contextHandler: { decision in
        await observations.record(decision)
        return [.text("no external evidence")]
      }
    )

    _ = try await exchange.handle(
      try incomingMessage(
        #"{"jsonrpc":"2.0","id":1,"method":"mien/request_context","params":{"sessionId":"\#(sessionID)","decision":{"schemaVersion":1,"kind":"none","request":null}}}"#
      )
    )
    _ = try await exchange.handle(
      try incomingMessage(
        #"{"jsonrpc":"2.0","id":2,"method":"mien/submit_outcome","params":{"sessionId":"\#(sessionID)","outcome":{"schemaVersion":1,"kind":"answer","content":"Hello"}}}"#
      )
    )

    let result = try await exchange.validatedResult()
    let decisions = await observations.decisions
    XCTAssertEqual(result.contextDecision, .none())
    XCTAssertEqual(result.outcome, AgentOutcome(kind: .answer, content: "Hello"))
    XCTAssertEqual(decisions, [.none()])
  }

  func testProtocolFailureNamesTheMissingPhase() async throws {
    let exchange = AgentTurnExchange(
      sessionID: "session",
      catalog: [],
      contextHandler: { _ in [.text("unused")] }
    )

    do {
      _ = try await exchange.validatedResult()
      XCTFail("Expected a missing context decision")
    } catch {
      XCTAssertEqual(
        error as? PiAgentBridgeError,
        .agentProtocolViolation(.missingContextDecision)
      )
    }
  }

  func testExchangePreservesTheFirstHostProtocolFailure() async throws {
    let sessionID = "session"
    let exchange = AgentTurnExchange(
      sessionID: sessionID,
      catalog: [],
      contextHandler: { _ in [.text("unused")] }
    )

    do {
      _ = try await exchange.handle(
        try incomingMessage(
          #"{"jsonrpc":"2.0","id":1,"method":"mien/request_context","params":{"sessionId":"session"}}"#
        )
      )
      XCTFail("Expected a malformed context decision")
    } catch {
      XCTAssertEqual(
        error as? PiAgentBridgeError,
        .agentProtocolViolation(.malformedContextDecision)
      )
    }

    _ = try? await exchange.handle(
      try incomingMessage(
        #"{"jsonrpc":"2.0","id":2,"method":"unknown","params":{"sessionId":"session"}}"#
      )
    )
    let recordedFailure = await exchange.recordedFailure() as? PiAgentBridgeError
    XCTAssertEqual(
      recordedFailure,
      .agentProtocolViolation(.malformedContextDecision)
    )
  }

  func testRuntimeProtocolCodesMapWithoutParsingRemoteProse() {
    let contextError = PiAgentBridge.normalizedRuntimeError(
      ACPConnectionError.remoteError(
        code: PiAgentRuntimeRPCErrorCode.missingContextDecision,
        message: "arbitrary remote prose"
      )
    )
    let outcomeError = PiAgentBridge.normalizedRuntimeError(
      ACPConnectionError.remoteError(
        code: PiAgentRuntimeRPCErrorCode.missingOutcome,
        message: "different arbitrary prose"
      )
    )

    XCTAssertEqual(
      contextError as? PiAgentBridgeError,
      .agentProtocolViolation(.missingContextDecision)
    )
    XCTAssertEqual(
      outcomeError as? PiAgentBridgeError,
      .agentProtocolViolation(.missingOutcome)
    )
  }

  func testCatalogFailureUsesOnlyTheTypedRuntimeCode() {
    let error = PiAgentBridge.normalizedRuntimeError(
      ACPConnectionError.remoteError(
        code: PiAgentRuntimeRPCErrorCode.modelCatalogUnavailable,
        message: "arbitrary provider prose"
      )
    )
    XCTAssertEqual(error as? PiAgentBridgeError, .modelCatalogUnavailable)
  }

  func testSettingsCatalogFailurePreservesAnExistingConversationBinding() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("catalog-fixture")
    let script = #"""
      #!/bin/zsh
      count=0
      while IFS= read -r line; do
        [[ "$line" =~ '"id"[[:space:]]*:[[:space:]]*([0-9]+)' ]] || continue
        request_id=$match[1]
        case "$line" in
          *initialize*) result='{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}' ;;
          *session/new*)
            (( count += 1 ))
            if (( count == 2 )); then
              print -r -- "{\"jsonrpc\":\"2.0\",\"id\":$request_id,\"error\":{\"code\":-32022,\"message\":\"catalog unavailable\"}}"
              continue
            fi
            result='{"sessionId":"kept-session","configOptions":[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"test","options":[{"value":"test","name":"Test"}]}]}' ;;
          *) result='{}' ;;
        esac
        print -r -- "{\"jsonrpc\":\"2.0\",\"id\":$request_id,\"result\":$result}"
      done
      """#
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let bridge = PiAgentBridge(
      configuration: try PiAgentBridgeConfiguration(
        process: ACPProcessConfiguration(executableURL: executable, workingDirectoryURL: directory),
        clientInfo: ACPImplementation(name: "test", title: nil, version: "1")
      )
    )
    addTeardownBlock {
      await bridge.stop()
      try? FileManager.default.removeItem(at: directory)
    }
    let conversationID = UUID()
    _ = try await bridge.openConversationTaskSession(
      taskID: UUID(), conversationID: conversationID, workingDirectory: directory
    )
    do {
      _ = try await bridge.discoverModels()
      XCTFail("Expected catalog failure")
    } catch {
      XCTAssertEqual(error as? PiAgentBridgeError, .modelCatalogUnavailable)
    }
    let preserved = await bridge.conversationIsValid(conversationID: conversationID)
    XCTAssertTrue(preserved)
  }

  func testAuthenticationUsesOnlyTheTypedRuntimeCode() {
    let authenticationError = PiAgentBridge.normalizedRuntimeError(
      ACPConnectionError.remoteError(
        code: PiAgentRuntimeRPCErrorCode.authenticationRequired,
        message: "arbitrary provider prose"
      )
    )
    XCTAssertEqual(authenticationError as? PiAgentBridgeError, .authenticationRequired)

    let unrelatedError = ACPConnectionError.remoteError(
      code: -32_020,
      message: "invalid_refresh_token: please sign in again"
    )
    XCTAssertEqual(
      PiAgentBridge.normalizedRuntimeError(unrelatedError) as? ACPConnectionError,
      unrelatedError
    )
  }

  func testBridgeRejectsAnEmptyModelPreferenceBeforeStartingAgent() async throws {
    let bridge = PiAgentBridge(
      configuration: try PiAgentBridgeConfiguration(
        process: ACPProcessConfiguration(
          executableURL: URL(fileURLWithPath: "/tmp/fake-mien-pi-agent"),
          workingDirectoryURL: FileManager.default.temporaryDirectory
        ),
        clientInfo: ACPImplementation(
          name: "mien-tests",
          title: "Mien Tests",
          version: "0.1.0"
        )
      )
    )

    do {
      _ = try await bridge.openTaskSession(
        taskID: UUID(),
        workingDirectory: FileManager.default.temporaryDirectory,
        preferredModelID: ""
      )
      XCTFail("Expected the empty model ID to be rejected")
    } catch {
      XCTAssertEqual(error as? PiAgentBridgeError, .invalidModelPreference)
    }
  }

  func testLivePiAgentUsesTypedToolsAndAppliesModelChangesToTheNextTurn() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RUN_PI_AGENT_LIVE_PROMPT"] == "1" else {
      throw XCTSkip("set RUN_PI_AGENT_LIVE_PROMPT=1 to exercise a real Pi tool loop")
    }
    let executable = try XCTUnwrap(environment["PI_AGENT_EXECUTABLE"])
    let agentDirectory = try XCTUnwrap(environment["PI_AGENT_DIR"])
    let alternateModelID = try XCTUnwrap(environment["PI_AGENT_ALTERNATE_MODEL_ID"])
    let workingDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: workingDirectory,
      withIntermediateDirectories: true
    )

    let bridge = PiAgentBridge(
      configuration: try PiAgentBridgeConfiguration(
        process: ACPProcessConfiguration(
          executableURL: URL(fileURLWithPath: executable),
          workingDirectoryURL: workingDirectory,
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
    )
    addTeardownBlock {
      await bridge.stop()
      try? FileManager.default.removeItem(at: workingDirectory)
    }
    let conversationID = UUID()
    let firstTaskID = UUID()
    let secondTaskID = UUID()
    let thirdTaskID = UUID()
    let now = Date()
    let window = WindowLease(
      processIdentifier: 99,
      windowID: 1234,
      bundleIdentifier: "com.apple.TextEdit",
      frame: ScreenRect(x: 0, y: 0, width: 800, height: 600),
      capturedAt: now,
      expiresAt: now.addingTimeInterval(180),
      userInputEpoch: 1
    )
    let target = TargetLease(
      invocationSnapshotID: UUID(),
      window: window,
      semanticTarget: AXElementFingerprint(
        role: "AXTextArea",
        frame: ScreenRect(x: 20, y: 20, width: 760, height: 560)
      ),
      issuedAt: now,
      expiresAt: window.expiresAt
    )
    let observations = ToolObservations()

    _ = try await bridge.connect()
    let catalog = try await bridge.discoverModels()
    if let expectedDefault = environment["PI_AGENT_EXPECTED_DEFAULT_MODEL_ID"] {
      XCTAssertEqual(catalog.currentModelID, expectedDefault)
    }
    let alternateModel = try XCTUnwrap(
      catalog.options.first {
        $0.id == alternateModelID && $0.id != catalog.currentModelID
      }
    )
    _ = try await bridge.openConversationTaskSession(
      taskID: firstTaskID,
      conversationID: conversationID,
      workingDirectory: workingDirectory,
      preferredModelID: alternateModel.id
    )
    let firstActivityStream = try await bridge.activityUpdates(taskID: firstTaskID)
    let firstActivityTask = Task { () -> [ACPAgentActivityUpdate] in
      var updates: [ACPAgentActivityUpdate] = []
      for await update in firstActivityStream {
        updates.append(update)
        if update.toolName == "submit_outcome", update.status == .completed {
          return updates
        }
      }
      return updates
    }
    defer { firstActivityTask.cancel() }
    let firstOutcome = try await bridge.runTurn(
      taskID: firstTaskID,
      userInput:
        "What deployment marker is visible in the current interface? Reply with only the marker.",
      target: target,
      capabilities: [
        AgentEvidenceCapability(kind: .accessibility, availability: .available)
      ],
      deadline: now.addingTimeInterval(90),
      contextHandler: { decision in
        let request = try XCTUnwrap(decision.request)
        await observations.record(request)
        return [.text("<untrusted-context>deployment marker: READY</untrusted-context>")]
      }
    )

    XCTAssertEqual(firstOutcome.contextDecision.kind, .request)
    XCTAssertEqual(firstOutcome.outcome.kind, .answer)
    XCTAssertEqual(
      firstOutcome.outcome.content.trimmingCharacters(in: .whitespacesAndNewlines),
      "READY"
    )
    let firstActivities = await firstActivityTask.value
    XCTAssertTrue(
      firstActivities.contains {
        $0.toolName == "request_context"
          && $0.title?.hasPrefix("request_context(") == true
          && $0.title?.contains("accessibility") == true
          && $0.status == .completed
      }
    )
    XCTAssertTrue(
      firstActivities.contains {
        $0.toolName == "submit_outcome"
          && $0.title == "submit_outcome(kind: answer)"
          && $0.status == .completed
      }
    )

    _ = try await bridge.openConversationTaskSession(
      taskID: secondTaskID,
      conversationID: conversationID,
      workingDirectory: workingDirectory,
      preferredModelID: nil
    )
    let secondOutcome = try await bridge.runTurn(
      taskID: secondTaskID,
      userInput:
        "What release marker is visible in the current interface? Reply with only the marker.",
      target: target,
      capabilities: [
        AgentEvidenceCapability(kind: .accessibility, availability: .available)
      ],
      deadline: Date().addingTimeInterval(90),
      contextHandler: { decision in
        let request = try XCTUnwrap(decision.request)
        await observations.record(request)
        return [.text("<untrusted-context>release marker: DEFAULT</untrusted-context>")]
      }
    )

    XCTAssertEqual(secondOutcome.contextDecision.kind, .request)
    XCTAssertEqual(secondOutcome.outcome.kind, .answer)
    XCTAssertEqual(
      secondOutcome.outcome.content.trimmingCharacters(in: .whitespacesAndNewlines),
      "DEFAULT"
    )
    let requestCount = await observations.count
    XCTAssertEqual(requestCount, 2)

    _ = try await bridge.openConversationTaskSession(
      taskID: thirdTaskID,
      conversationID: conversationID,
      workingDirectory: workingDirectory,
      preferredModelID: nil
    )
    let noContextActivities = try await bridge.activityUpdates(taskID: thirdTaskID)
    let noContextActivityTask = Task { () -> [ACPAgentActivityUpdate] in
      var updates: [ACPAgentActivityUpdate] = []
      for await update in noContextActivities {
        updates.append(update)
        if update.toolName == "submit_outcome", update.status == .completed {
          return updates
        }
      }
      return updates
    }
    defer { noContextActivityTask.cancel() }
    let noContextResult = try await bridge.runTurn(
      taskID: thirdTaskID,
      userInput:
        "This request is self-contained. Do not inspect the target. Reply to this greeting in one short sentence: hi",
      target: target,
      capabilities: [
        AgentEvidenceCapability(kind: .accessibility, availability: .available)
      ],
      deadline: Date().addingTimeInterval(90),
      contextHandler: { _ in
        return [.text("no external evidence was acquired")]
      }
    )

    XCTAssertEqual(noContextResult.contextDecision, .none())
    XCTAssertEqual(noContextResult.outcome.kind, .answer)
    XCTAssertFalse(
      noContextResult.outcome.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    )
    let noContextActivity = await noContextActivityTask.value
    XCTAssertTrue(
      noContextActivity.contains {
        $0.toolName == "request_context"
          && $0.title == "request_context(kind: none)"
          && $0.status == .completed
      }
    )
    let recallTaskID = UUID()
    _ = try await bridge.openConversationTaskSession(
      taskID: recallTaskID,
      conversationID: conversationID,
      workingDirectory: workingDirectory,
      preferredModelID: nil
    )
    let recall = try await bridge.runTurn(
      taskID: recallTaskID,
      userInput:
        "Based only on our conversation, repeat the deployment marker and release marker you previously answered, in that order, separated by one space. Do not inspect the target.",
      target: target,
      capabilities: [AgentEvidenceCapability(kind: .accessibility, availability: .available)],
      deadline: Date().addingTimeInterval(90),
      contextHandler: { decision in
        XCTAssertEqual(decision, .none())
        return [.text("no external evidence was acquired")]
      }
    )
    XCTAssertEqual(recall.contextDecision, .none())
    XCTAssertEqual(
      recall.outcome.content.trimmingCharacters(in: .whitespacesAndNewlines), "READY DEFAULT")
    await bridge.closeConversation(conversationID: conversationID)
    await bridge.stop()
  }
}

private func incomingMessage(_ json: String) throws -> JSONRPCIncomingMessage {
  try NDJSONRPCCodec().decode(Data(json.utf8))
}

private actor ContextDecisionObservations {
  private(set) var decisions: [AgentContextDecision] = []

  func record(_ decision: AgentContextDecision) {
    decisions.append(decision)
  }
}

private actor ToolObservations {
  private(set) var count = 0

  func record(_ request: AgentContextRequest) {
    count += 1
  }
}
