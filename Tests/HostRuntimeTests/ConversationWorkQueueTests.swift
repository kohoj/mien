import XCTest

@testable import HostRuntime

@MainActor
final class ConversationWorkQueueTests: XCTestCase {
  func testNewTurnWaitsForCancelledTurnAndUncancelledCleanup() async {
    let queue = ConversationWorkQueue()
    var events: [String] = []
    queue.submit {
      events.append("running")
      do { try await Task.sleep(for: .seconds(10)) } catch { events.append("cancelled") }
    }
    await Task.yield()
    queue.cleanup {
      XCTAssertFalse(Task.isCancelled)
      events.append("cleanup")
      await Task.yield()
      XCTAssertFalse(Task.isCancelled)
      events.append("clean")
    }
    queue.submit { events.append("next") }
    await queue.waitForIdle()
    XCTAssertEqual(events, ["running", "cancelled", "cleanup", "clean", "next"])
  }

  func testDismissBeforeQueuedTurnStartsStillDrainsCleanup() async {
    let queue = ConversationWorkQueue()
    var events: [String] = []
    queue.cleanup {
      await Task.yield()
      events.append("first cleanup")
    }
    queue.submit { XCTFail("Cancelled queued work must not execute") }
    queue.cleanup { events.append("second cleanup") }
    await queue.waitForIdle()
    XCTAssertEqual(events, ["first cleanup", "second cleanup"])
  }

  func testCleanupCancelsActiveWorkEvenWhenAContinuationIsQueued() async {
    let queue = ConversationWorkQueue()
    var events: [String] = []
    queue.submit {
      events.append("active")
      do { try await Task.sleep(for: .seconds(10)) } catch { events.append("cancelled") }
    }
    await Task.yield()
    queue.continueWith { XCTFail("A cancelled pending action must not execute") }
    queue.cleanup { events.append("cleanup") }
    await queue.waitForIdle()
    XCTAssertEqual(events, ["active", "cancelled", "cleanup"])
  }
}
