import Foundation
import ProviderAdapters
import XCTest

final class ProcessRunnerTests: XCTestCase {
  func testCancellationTerminatesAStuckProcessWithinTheGraceFence() async throws {
    let runner = FoundationProcessRunner(
      maximumRuntime: .seconds(20),
      terminationGrace: .milliseconds(200)
    )
    let clock = ContinuousClock()
    let start = clock.now
    let operation = Task {
      try await runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "trap '' TERM; sleep 20"],
        environment: ["PATH": "/usr/bin:/bin"]
      )
    }

    try await Task.sleep(for: .milliseconds(80))
    operation.cancel()

    do {
      _ = try await operation.value
      XCTFail("expected cancellation")
    } catch is CancellationError {
      XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
    }
  }

  func testRuntimeDeadlineTerminatesTheProcess() async throws {
    let runner = FoundationProcessRunner(
      maximumRuntime: .milliseconds(80),
      terminationGrace: .milliseconds(200)
    )

    do {
      _ = try await runner.run(
        executable: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["20"],
        environment: [:]
      )
      XCTFail("expected timeout")
    } catch {
      XCTAssertEqual(error as? ProcessRunnerError, .timedOut)
    }
  }
}
