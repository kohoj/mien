import Foundation
import SubprocessKernel
import XCTest

final class ManagedSubprocessTests: XCTestCase {
  func testTerminateAndWaitReapsTheOwnedProcessBeforeReturning() async throws {
    let process = try ManagedSubprocess.launch(
      executable: URL(fileURLWithPath: "/bin/sleep"),
      arguments: ["30"],
      environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    )
    let waiter = Task.detached(priority: .utility) { try process.wait() }

    let terminated = await process.terminateAndWait(grace: .milliseconds(50))
    XCTAssertTrue(terminated)
    _ = try await waiter.value
    XCTAssertFalse(process.isRunning)
  }
}
