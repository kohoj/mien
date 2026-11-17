import ACPGateway
import Foundation
import XCTest

@testable import Mien

@MainActor
final class RuntimeBootstrapTests: XCTestCase {
  func testPreparationRecoversBeforeReturning() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("Support")
    let orphan = support.appendingPathComponent("Conversations/orphan")
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    let bootstrap = MienRuntimeBootstrap(
      bundleURL: root, resourceURL: root, environment: [:], supportURL: support)
    let prepared = try await bootstrap.prepare()
    XCTAssertEqual(prepared.supportURL, support)
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    XCTAssertNil(prepared.agentBridge)
    XCTAssertEqual(prepared.readiness, .unavailable)
  }

  func testCorruptJournalCannotProduceAReadyRuntime() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("invalid complete record\n".utf8).write(
      to: root.appendingPathComponent("task-events.jsonl"))
    let bootstrap = MienRuntimeBootstrap(
      bundleURL: root, resourceURL: root, environment: [:], supportURL: root)
    do {
      _ = try await bootstrap.prepare()
      XCTFail("Corrupt durable task truth must prevent startup")
    } catch {}
  }

  func testInstalledRuntimePreparationProbe() async throws {
    guard ProcessInfo.processInfo.environment["MIEN_STARTUP_PROBE"] == "1" else {
      throw XCTSkip("Opt-in installed runtime preparation and main-actor latency probe")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = URL(fileURLWithPath: "/Applications/Mien.app")
    let bootstrap = MienRuntimeBootstrap(
      bundleURL: bundle, resourceURL: bundle.appendingPathComponent("Contents/Resources"),
      environment: [:], supportURL: root)
    // Reproduce the previous launch boundary with the same installed helpers.
    let digests =
      try JSONSerialization.jsonObject(
        with: Data(
          contentsOf: bundle.appendingPathComponent("Contents/Resources/runtime-digests.json")))
      as! [String: String]
    let legacyStart = ContinuousClock.now
    for (name, key) in [("mien-pi-agent", "piAgent"), ("longview", "longview")] {
      try ExecutableIntegrity.verify(
        bundle.appendingPathComponent("Contents/Helpers/" + name),
        expectedSHA256: try XCTUnwrap(digests[key]), requireValidCodeSignature: true)
    }
    print("STARTUP_BASELINE mainActorIntegrity=\(legacyStart.duration(to: .now))")
    var maximumGap = Duration.zero
    var beats = 0
    let heartbeat = Task { @MainActor in
      var last = ContinuousClock.now
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
        let now = ContinuousClock.now
        maximumGap = max(maximumGap, last.duration(to: now))
        last = now
        beats += 1
      }
    }
    let start = ContinuousClock.now
    _ = try await bootstrap.prepare()
    heartbeat.cancel()
    await heartbeat.value
    print(
      "STARTUP_PROBE prepare=\(start.duration(to: .now)) mainActorMaximumGap=\(maximumGap) beats=\(beats)"
    )
    XCTAssertGreaterThan(beats, 0, "Integrity verification must yield the MainActor")
  }
}
