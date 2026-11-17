import Foundation
import XCTest

@testable import HostRuntime

final class CodexDeviceLoginCoordinatorTests: XCTestCase {
  func testLiveBundledLoginPublishesAuthorizationBeforeProcessExit() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RUN_PI_AGENT_LIVE_LOGIN"] == "1" else {
      throw XCTSkip("set RUN_PI_AGENT_LIVE_LOGIN=1 to exercise the bundled device-login flow")
    }
    let executable = try XCTUnwrap(environment["PI_AGENT_EXECUTABLE"])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = CodexDeviceLoginCoordinator(
      configuration: try CodexDeviceLoginConfiguration(
        executableURL: URL(fileURLWithPath: executable),
        codexHomeURL: directory,
        workingDirectoryURL: directory,
        environment: ["PATH": "/usr/bin:/bin"],
        deadline: 30
      )
    )
    let authorizationShown = expectation(
      description: "real device code reaches App before authorization")
    let login = Task {
      try await coordinator.authenticate { authorization in
        XCTAssertEqual(
          authorization.verificationURL.absoluteString, "https://auth.openai.com/codex/device")
        XCTAssertFalse(authorization.userCode.isEmpty)
        authorizationShown.fulfill()
      }
    }
    await fulfillment(of: [authorizationShown], timeout: 20)
    login.cancel()
    do {
      try await login.value
      XCTFail("Probe must stop before user authorization")
    } catch is CancellationError {
      // This probe needs no real credential or user interaction.
    }
  }

  func testAppLoginPublishesCodeThenWaitsForAuthorizationAndPrivateCredential() async throws {
    let (directory, coordinator) = try loginFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let authorizationShown = expectation(
      description: "App receives official login destination and code")

    try await coordinator.authenticate { authorization in
      XCTAssertEqual(
        authorization.verificationURL.absoluteString, "https://auth.openai.com/codex/device")
      XCTAssertEqual(authorization.userCode, "ABCD-EFGH1")
      authorizationShown.fulfill()
      try? Data().write(to: directory.appendingPathComponent("approved"))
    }
    await fulfillment(of: [authorizationShown], timeout: 1)
    XCTAssertTrue(try PiCodexCredentialImporter().validate(piHome: directory))
  }

  func testCancellationDuringBrowserAuthorizationCannotCompleteLogin() async throws {
    let (directory, coordinator) = try loginFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let authorizationShown = expectation(description: "waiting for browser authorization")
    let login = Task {
      try await coordinator.authenticate { _ in authorizationShown.fulfill() }
    }
    await fulfillment(of: [authorizationShown], timeout: 2)
    login.cancel()
    do {
      try await login.value
      XCTFail("Cancelled browser authorization must not complete")
    } catch is CancellationError {
      // A user cancellation is not a login failure that reopens Settings.
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("auth.json").path))
  }

  private func loginFixture() throws -> (URL, CodexDeviceLoginCoordinator) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("login-fixture")
    let script = #"""
      #!/bin/zsh
      [[ "$1" == login ]] || exit 64
      print 'https://auth.openai.com/codex/device'
      print 'ABCD-EFGH1'
      for attempt in {1..200}; do
        if [[ -f "$PI_AGENT_DIR/approved" ]]; then
          umask 077
          print '{"openai-codex":{"type":"oauth","access":"fixture-access","refresh":"fixture-refresh","accountId":"fixture-account","expires":4102444800000}}' > "$PI_AGENT_DIR/auth.json"
          exit 0
        fi
        sleep 0.01
      done
      exit 1
      """#
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let coordinator = CodexDeviceLoginCoordinator(
      configuration: try CodexDeviceLoginConfiguration(
        executableURL: executable,
        codexHomeURL: directory,
        workingDirectoryURL: directory,
        environment: ["PATH": "/usr/bin:/bin"],
        deadline: 30
      )
    )
    return (directory, coordinator)
  }

  func testParserWaitsForBothURLAndCompleteCodeAcrossChunks() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let accumulator = DeviceLoginOutputAccumulator { _ in }

    await accumulator.ingest(
      Data("Open https://auth.openai.com/codex/device and enter ABCD-".utf8),
      now: now
    )
    let publishedBeforeCode = await accumulator.didPublishAuthorization
    XCTAssertFalse(publishedBeforeCode)

    await accumulator.ingest(Data("EFGH1\n".utf8), now: now)

    let publishedAfterCode = await accumulator.didPublishAuthorization
    XCTAssertTrue(publishedAfterCode)
  }

  func testParserRemovesTerminalColorWithoutAcceptingAnotherOrigin() throws {
    let now = Date(timeIntervalSince1970: 2_000)
    let text = """
      \u{001B}[94mhttps://auth.openai.com/codex/device\u{001B}[0m
      \u{001B}[94mTL3K-CWLL6\u{001B}[0m
      """

    let authorization = try XCTUnwrap(DeviceLoginOutputParser.parse(text, now: now))

    XCTAssertEqual(
      authorization.verificationURL.absoluteString, "https://auth.openai.com/codex/device")
    XCTAssertEqual(authorization.userCode, "TL3K-CWLL6")
    XCTAssertEqual(authorization.expiresAt, now.addingTimeInterval(15 * 60))
    XCTAssertNil(
      DeviceLoginOutputParser.parse(
        "https://example.com/codex/device\nTL3K-CWLL6",
        now: now
      ))
  }
}
