import Foundation
import InteractionShell
import MienContracts
import XCTest

final class TaskPresentationTests: XCTestCase {
  func testCleanupProjectsThePreservedTerminalOutcome() throws {
    let taskID = UUID()
    let events = [
      event(taskID: taskID, sequence: 0, previous: nil, state: .created),
      event(taskID: taskID, sequence: 1, previous: .created, state: .targetLocked),
      event(taskID: taskID, sequence: 2, previous: .targetLocked, state: .contextReady),
      event(taskID: taskID, sequence: 3, previous: .contextReady, state: .agentRunning),
      event(taskID: taskID, sequence: 4, previous: .agentRunning, state: .succeeded),
      event(taskID: taskID, sequence: 5, previous: .succeeded, state: .cleanupVerified),
    ]

    let presentation = try XCTUnwrap(
      TaskPresentationReducer().reduce(events: events, result: "Draft")
    )

    XCTAssertEqual(presentation.status, "已完成")
    XCTAssertEqual(presentation.result, "Draft")
    XCTAssertEqual(presentation.sequence, 5)
  }

  func testFailedTaskNeverProjectsAgentTextAsAResult() throws {
    let taskID = UUID()
    let events = [
      event(taskID: taskID, sequence: 0, previous: nil, state: .created),
      event(taskID: taskID, sequence: 1, previous: .created, state: .failed),
    ]

    let presentation = try XCTUnwrap(
      TaskPresentationReducer().reduce(events: events, result: "partial model text")
    )

    XCTAssertEqual(presentation.status, "任务未完成")
    XCTAssertNil(presentation.result)
    XCTAssertTrue(presentation.allowsRetry)
  }

  private func event(
    taskID: UUID,
    sequence: UInt64,
    previous: TaskState?,
    state: TaskState
  ) -> TaskEvent {
    TaskEvent(
      taskID: taskID,
      sequence: sequence,
      occurredAt: Date(),
      actor: .host,
      previousState: previous,
      state: state,
      reason: "test"
    )
  }
}
