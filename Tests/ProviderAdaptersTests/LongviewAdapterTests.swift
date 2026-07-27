import Foundation
import MienContracts
import ProviderAdapters
import XCTest

final class LongviewAdapterTests: XCTestCase {
  func testAdapterPinsWindowIdentityAndAcceptsOnlyVerifiedRestoration() async throws {
    let now = Date()
    let target = makeTarget(now: now)
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let outputURL = temporaryDirectory.appendingPathComponent("context.png")
    try Data("png".utf8).write(to: outputURL)

    let runner = StubProcessRunner(
      output: ProcessOutput(
        status: 0,
        standardOutput: Data(
          (successEnvelope(
            target: target,
            outputURL: outputURL,
            restorationSucceeded: true
          ) + "\n").utf8),
        standardError: Data()
      ))
    let adapter = try LongviewAdapter(
      executableURL: URL(fileURLWithPath: "/usr/local/bin/longview"),
      runner: runner
    )
    let outcome = try await adapter.capture(
      LongviewCaptureRequest(
        taskID: UUID(),
        target: target,
        outputURL: outputURL,
        maximumFrames: 8,
        focusPolicy: .backgroundOnly
      ), now: now)

    XCTAssertEqual(outcome.artifact.provider, .longview)
    XCTAssertEqual(outcome.artifact.scope, .boundedHistory)
    XCTAssertFalse(outcome.artifact.complete)
    XCTAssertEqual(outcome.stopReason, .frameLimitReached)
    XCTAssertTrue(outcome.receipt.isVerifiedSuccess)
    XCTAssertEqual(
      runner.arguments,
      [
        "--events", "longshot",
        "--output", outputURL.path,
        "--window-id", String(target.window.windowID),
        "--bundle-id", target.window.bundleIdentifier,
        "--max-frames", "8",
        "--focus-policy", "background-only",
      ])
  }

  func testAdapterFailsClosedWhenRestorationIsUnverified() async throws {
    let now = Date()
    let target = makeTarget(now: now)
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).png")
    try Data("png".utf8).write(to: outputURL)
    defer { try? FileManager.default.removeItem(at: outputURL) }

    let runner = StubProcessRunner(
      output: ProcessOutput(
        status: 0,
        standardOutput: Data(
          (successEnvelope(
            target: target,
            outputURL: outputURL,
            restorationSucceeded: false
          ) + "\n").utf8),
        standardError: Data()
      ))
    let adapter = try LongviewAdapter(
      executableURL: URL(fileURLWithPath: "/usr/local/bin/longview"),
      runner: runner
    )

    do {
      _ = try await adapter.capture(
        LongviewCaptureRequest(
          taskID: UUID(),
          target: target,
          outputURL: outputURL,
          maximumFrames: 8,
          focusPolicy: .backgroundOnly
        ), now: now)
      XCTFail("Expected unverified restoration to fail closed")
    } catch {
      XCTAssertEqual(error as? LongviewAdapterError, .restorationUnverified)
    }
  }

  private func makeTarget(now: Date) -> TargetLease {
    TargetLease(
      invocationSnapshotID: UUID(),
      window: WindowLease(
        processIdentifier: 42,
        windowID: 99,
        bundleIdentifier: "com.tencent.xinWeChat",
        frame: ScreenRect(x: 0, y: 0, width: 800, height: 600),
        capturedAt: now,
        expiresAt: now.addingTimeInterval(60),
        userInputEpoch: 1
      ),
      semanticTarget: nil,
      issuedAt: now,
      expiresAt: now.addingTimeInterval(30)
    )
  }

  private func successEnvelope(
    target: TargetLease,
    outputURL: URL,
    restorationSucceeded: Bool
  ) -> String {
    """
    {"schemaVersion":2,"type":"result","ok":true,"command":"longshot","result":{"target":{"processIdentifier":\(target.window.processIdentifier),"windowNumber":\(target.window.windowID)},"outputPath":"\(outputURL.path)","pixelWidth":747,"pixelHeight":3104,"capturedFrameCount":8,"detectedOverlaps":[120,118,121,119,120,118,120],"scrollRoute":"accessibility-value","stopReason":"frame-limit-reached","targetWasActivated":false,"pointerWasMoved":false,"viewportRestorationAttempted":true,"viewportRestorationSucceeded":\(restorationSucceeded),"environmentRestorationSucceeded":\(restorationSucceeded),"focusRestorationSucceeded":true,"pointerRestorationSucceeded":true,"effectivePixelsPerSecond":1000}}
    """
  }
}

private final class StubProcessRunner: ProcessRunning, @unchecked Sendable {
  let output: ProcessOutput
  private(set) var arguments: [String] = []

  init(output: ProcessOutput) {
    self.output = output
  }

  func run(
    executable: URL,
    arguments: [String],
    environment: [String: String]
  ) async throws -> ProcessOutput {
    self.arguments = arguments
    return output
  }
}
