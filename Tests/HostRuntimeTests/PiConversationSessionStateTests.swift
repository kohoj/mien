import ACPGateway
import Foundation
import MienContracts
import XCTest

@testable import HostRuntime

final class PiConversationSessionStateTests: XCTestCase {
  func testReleasePreservesConversationAndAllowsOneFreshTask() throws {
    let conversationID = UUID()
    let firstTaskID = UUID()
    let secondTaskID = UUID()
    var state = PiConversationSessionState()
    state.registerConversation(
      id: conversationID,
      sessionID: "session-one",
      agentDefaultModelID: "model-default",
      modelConfiguration: modelConfiguration(currentModelID: "model-one"),
      preferredModelID: "model-one"
    )
    try state.bind(
      taskID: firstTaskID,
      conversationID: conversationID,
      sessionID: "session-one",
      closesAfterTask: false
    )

    XCTAssertThrowsError(
      try state.bind(
        taskID: secondTaskID,
        conversationID: conversationID,
        sessionID: "session-one",
        closesAfterTask: false
      )
    ) { error in
      XCTAssertEqual(error as? PiAgentBridgeError, .taskSessionAlreadyOpen)
    }

    let released = try state.releaseTaskBindingPreservingConversation(taskID: firstTaskID)

    XCTAssertEqual(released.conversationID, conversationID)
    XCTAssertNil(state.binding(taskID: firstTaskID))
    XCTAssertEqual(state.conversation(id: conversationID)?.sessionID, "session-one")

    try state.bind(
      taskID: secondTaskID,
      conversationID: conversationID,
      sessionID: "session-one",
      closesAfterTask: false
    )
    XCTAssertEqual(state.binding(taskID: secondTaskID)?.conversationID, conversationID)
  }

  func testInvalidationRemovesConversationAndItsBinding() throws {
    let conversationID = UUID()
    let taskID = UUID()
    var state = PiConversationSessionState()
    state.registerConversation(
      id: conversationID,
      sessionID: "session-one",
      agentDefaultModelID: "model-default",
      modelConfiguration: modelConfiguration(),
      preferredModelID: nil
    )
    try state.bind(
      taskID: taskID,
      conversationID: conversationID,
      sessionID: "session-one",
      closesAfterTask: false
    )

    let invalidated = state.invalidateConversation(id: conversationID)

    XCTAssertEqual(invalidated?.sessionID, "session-one")
    XCTAssertNil(state.conversation(id: conversationID))
    XCTAssertNil(state.binding(taskID: taskID))
  }

  func testLegacyTaskCannotReleaseWhilePreservingConversation() throws {
    let conversationID = UUID()
    let taskID = UUID()
    var state = PiConversationSessionState()
    state.registerConversation(
      id: conversationID,
      sessionID: "legacy-session",
      agentDefaultModelID: "model-default",
      modelConfiguration: modelConfiguration(),
      preferredModelID: nil
    )
    try state.bind(
      taskID: taskID,
      conversationID: conversationID,
      sessionID: "legacy-session",
      closesAfterTask: true
    )

    XCTAssertThrowsError(
      try state.releaseTaskBindingPreservingConversation(taskID: taskID)
    ) { error in
      XCTAssertEqual(error as? PiAgentBridgeError, .taskSessionUnavailable)
    }
    XCTAssertNotNil(state.binding(taskID: taskID))
    XCTAssertNotNil(state.conversation(id: conversationID))
  }

  func testIdleConversationCanChangeModelBeforeTheNextTask() throws {
    let conversationID = UUID()
    var state = PiConversationSessionState()
    state.registerConversation(
      id: conversationID,
      sessionID: "session-one",
      agentDefaultModelID: "model-default",
      modelConfiguration: modelConfiguration(),
      preferredModelID: nil
    )

    try state.updateModelSelection(
      conversationID: conversationID,
      configuration: modelConfiguration(currentModelID: "model-sol"),
      preferredModelID: "model-sol"
    )

    let conversation = try XCTUnwrap(state.conversation(id: conversationID))
    XCTAssertEqual(conversation.preferredModelID, "model-sol")
    XCTAssertEqual(conversation.effectiveModelID, "model-sol")
    XCTAssertEqual(conversation.modelConfiguration.catalog.currentModelID, "model-sol")
  }

  func testActiveConversationRejectsAMidTurnModelChange() throws {
    let conversationID = UUID()
    let taskID = UUID()
    var state = PiConversationSessionState()
    state.registerConversation(
      id: conversationID,
      sessionID: "session-one",
      agentDefaultModelID: "model-default",
      modelConfiguration: modelConfiguration(),
      preferredModelID: nil
    )
    try state.bind(
      taskID: taskID,
      conversationID: conversationID,
      sessionID: "session-one",
      closesAfterTask: false
    )

    XCTAssertThrowsError(
      try state.updateModelSelection(
        conversationID: conversationID,
        configuration: modelConfiguration(currentModelID: "model-sol"),
        preferredModelID: "model-sol"
      )
    ) { error in
      XCTAssertEqual(error as? PiAgentBridgeError, .taskSessionAlreadyOpen)
    }
    XCTAssertNil(state.conversation(id: conversationID)?.preferredModelID)
  }

  func testReturningToAgentDefaultRestoresTheOriginalConversationDefault() throws {
    let conversationID = UUID()
    var state = PiConversationSessionState()
    state.registerConversation(
      id: conversationID,
      sessionID: "session-one",
      agentDefaultModelID: "model-default",
      modelConfiguration: modelConfiguration(currentModelID: "model-sol"),
      preferredModelID: "model-sol"
    )

    try state.updateModelSelection(
      conversationID: conversationID,
      configuration: modelConfiguration(),
      preferredModelID: nil
    )

    let conversation = try XCTUnwrap(state.conversation(id: conversationID))
    XCTAssertNil(conversation.preferredModelID)
    XCTAssertEqual(conversation.effectiveModelID, "model-default")
  }

  private func modelConfiguration(
    currentModelID: String = "model-default"
  ) -> ACPAgentModelConfiguration {
    ACPAgentModelConfiguration(
      configID: "model",
      catalog: AgentModelCatalog(
        currentModelID: currentModelID,
        options: [
          AgentModelOption(id: "model-default", name: "Default"),
          AgentModelOption(id: "model-one", name: "One"),
          AgentModelOption(id: "model-sol", name: "Sol"),
        ]
      )
    )
  }
}
