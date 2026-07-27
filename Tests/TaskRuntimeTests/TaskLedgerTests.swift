import Foundation
import MienContracts
import TaskRuntime
import XCTest

final class TaskLedgerTests: XCTestCase {
  func testLedgerIsMonotonicAndRejectsSkippedOwnershipStages() async throws {
    let now = Date()
    let ledger = try TaskLedger(capsule: makeCapsule(now: now), now: now)

    await assertThrowsErrorAsync(
      try await ledger.transition(
        to: .executing,
        actor: .agent,
        reason: "agent attempted to bypass context"
      )
    ) { error in
      XCTAssertEqual(
        error as? TaskLedgerError,
        .invalidTransition(from: .created, to: .executing)
      )
    }

    try await ledger.transition(to: .targetLocked, actor: .host, reason: "lease verified")
    try await ledger.transition(to: .contextReady, actor: .host, reason: "manifest ready")
    try await ledger.transition(to: .agentRunning, actor: .agent, reason: "prompt accepted")
    try await ledger.transition(to: .succeeded, actor: .verifier, reason: "read-only result ready")
    try await ledger.transition(to: .cleanupVerified, actor: .verifier, reason: "no residual state")

    let events = await ledger.events()
    let finalState = await ledger.currentState
    let terminalOutcome = await ledger.terminalOutcome
    XCTAssertEqual(events.map(\.sequence), [0, 1, 2, 3, 4, 5])
    XCTAssertEqual(finalState, .cleanupVerified)
    XCTAssertEqual(terminalOutcome, .succeeded)
  }

  func testCancelledMutationCanRestoreBeforeClosing() async throws {
    let now = Date()
    let ledger = try TaskLedger(capsule: makeCapsule(now: now), now: now)

    try await ledger.transition(to: .targetLocked, actor: .host, reason: "lease verified")
    try await ledger.transition(to: .contextReady, actor: .host, reason: "manifest ready")
    try await ledger.transition(to: .agentRunning, actor: .agent, reason: "prompt accepted")
    try await ledger.transition(to: .executing, actor: .executor, reason: "draft transaction")
    try await ledger.transition(to: .cancelled, actor: .user, reason: "user cancelled")
    try await ledger.transition(to: .restoring, actor: .host, reason: "cleanup transaction")
    try await ledger.transition(
      to: .partial, actor: .verifier, reason: "user input suppressed focus restore")
    try await ledger.transition(
      to: .cleanupVerified, actor: .verifier, reason: "residual state declared")

    let finalState = await ledger.currentState
    let terminalOutcome = await ledger.terminalOutcome
    XCTAssertEqual(finalState, .cleanupVerified)
    XCTAssertEqual(terminalOutcome, .partial)
  }

  func testPrivateJSONLJournalReplaysMonotonicTaskTruth() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let file = root.appendingPathComponent("events.jsonl")
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = try JSONLTaskEventJournal(fileURL: file)
    let now = Date()
    let ledger = try TaskLedger(capsule: makeCapsule(now: now), now: now)
    try await ledger.transition(
      to: .targetLocked,
      actor: .host,
      reason: "lease verified",
      now: now
    )

    try await journal.append(await ledger.events())
    let replayed = try await journal.replay()

    XCTAssertEqual(replayed.map(\.sequence), [0, 1])
    XCTAssertEqual(replayed.map(\.state), [.created, .targetLocked])
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testJournalQuarantinesOnlyATornTrailingRecord() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let file = root.appendingPathComponent("events.jsonl")
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = try JSONLTaskEventJournal(fileURL: file)
    let now = Date()
    let event = TaskEvent(
      taskID: UUID(),
      sequence: 0,
      occurredAt: now,
      actor: .host,
      previousState: nil,
      state: .created,
      reason: "created"
    )
    try await journal.append([event])
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"taskID":"torn""#.utf8))
    try handle.close()

    let recovery = try await journal.repairTrailingRecord()
    let replayed = try await journal.replay()

    XCTAssertEqual(recovery, .quarantined(byteCount: 16))
    XCTAssertEqual(replayed.map(\.id), [event.id])
    XCTAssertEqual(replayed.map(\.state), [.created])
    let quarantineFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
      .filter { $0.contains("recovered-tail") }
    XCTAssertEqual(quarantineFiles.count, 1)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: root.appendingPathComponent(quarantineFiles[0]).path
    )
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testJournalRotatesWithoutALifetimeByteCeilingAndReplaysEverySegment() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let file = root.appendingPathComponent("events.jsonl")
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = try JSONLTaskEventJournal(fileURL: file, maximumBytes: 700)
    let now = Date()
    let events = (0..<12).map { index in
      TaskEvent(
        taskID: UUID(),
        sequence: 0,
        occurredAt: now.addingTimeInterval(Double(index)),
        actor: .host,
        previousState: nil,
        state: .created,
        reason: "created task \(index)"
      )
    }

    for event in events {
      try await journal.append([event])
    }
    let replayed = try await journal.replay()

    XCTAssertEqual(replayed.map(\.id), events.map(\.id))
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
    let segments = names.filter { $0.hasPrefix("events.") && $0.hasSuffix(".jsonl") }
    XCTAssertGreaterThan(segments.count, 1)
    for name in segments + ["events.jsonl"] {
      let path = root.appendingPathComponent(name).path
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
      XCTAssertLessThanOrEqual((attributes[.size] as? NSNumber)?.intValue ?? 0, 700)
    }
  }

  func testReplayRejectsASubstitutedImmutableSegment() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let file = root.appendingPathComponent("events.jsonl")
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = try JSONLTaskEventJournal(fileURL: file, maximumBytes: 512)
    let now = Date()
    for index in 0..<4 {
      try await journal.append([
        TaskEvent(
          taskID: UUID(),
          sequence: 0,
          occurredAt: now,
          actor: .host,
          previousState: nil,
          state: .created,
          reason: String(repeating: "x", count: 120 + index)
        )
      ])
    }
    let segment = root.appendingPathComponent("events.00000001.jsonl")
    XCTAssertTrue(FileManager.default.fileExists(atPath: segment.path))
    let moved = root.appendingPathComponent("segment-backup")
    try FileManager.default.moveItem(at: segment, to: moved)
    try FileManager.default.createSymbolicLink(at: segment, withDestinationURL: moved)

    await assertThrowsErrorAsync(try await journal.replay()) { error in
      XCTAssertEqual(error as? TaskEventJournalError, .symbolicLinkRejected)
    }
  }

  func testStartupRecoveryClosesOnlyTasksWithVerifiedDesktopRestoration() throws {
    let now = Date()
    let recoverableTaskID = UUID()
    let uncertainTaskID = UUID()
    let events = [
      TaskEvent(
        taskID: recoverableTaskID,
        sequence: 0,
        occurredAt: now,
        actor: .host,
        previousState: nil,
        state: .created,
        reason: "created"
      ),
      TaskEvent(
        taskID: recoverableTaskID,
        sequence: 1,
        occurredAt: now,
        actor: .host,
        previousState: .created,
        state: .targetLocked,
        reason: "target locked"
      ),
      TaskEvent(
        taskID: recoverableTaskID,
        sequence: 2,
        occurredAt: now,
        actor: .host,
        previousState: .targetLocked,
        state: .contextReady,
        reason: "context ready",
        desktopRecoveryVerified: true
      ),
      TaskEvent(
        taskID: uncertainTaskID,
        sequence: 0,
        occurredAt: now,
        actor: .host,
        previousState: nil,
        state: .created,
        reason: "created"
      ),
      TaskEvent(
        taskID: uncertainTaskID,
        sequence: 1,
        occurredAt: now,
        actor: .host,
        previousState: .created,
        state: .targetLocked,
        reason: "capture interrupted"
      ),
    ]

    let plans = try TaskRecoveryAuditor.plans(for: events)
    let recoverable = try XCTUnwrap(plans.first { $0.taskID == recoverableTaskID })
    let uncertain = try XCTUnwrap(plans.first { $0.taskID == uncertainTaskID })

    XCTAssertEqual(
      TaskRecoveryAuditor.recoveryEvents(for: recoverable, localResidueRemoved: true).map(\.state),
      [.failed, .cleanupVerified]
    )
    XCTAssertEqual(
      TaskRecoveryAuditor.recoveryEvents(for: uncertain, localResidueRemoved: true).map(\.state),
      [.failed]
    )
    XCTAssertEqual(uncertain.desktopRecovery, .unknown)
  }

  func testStartupRecoveryRejectsBrokenJournalSequence() {
    let taskID = UUID()
    let now = Date()
    let events = [
      TaskEvent(
        taskID: taskID,
        sequence: 0,
        occurredAt: now,
        actor: .host,
        previousState: nil,
        state: .created,
        reason: "created"
      ),
      TaskEvent(
        taskID: taskID,
        sequence: 2,
        occurredAt: now,
        actor: .host,
        previousState: .created,
        state: .targetLocked,
        reason: "broken sequence"
      ),
    ]

    XCTAssertThrowsError(try TaskRecoveryAuditor.plans(for: events))
  }

  private func makeCapsule(now: Date) -> TaskCapsule {
    TaskCapsule(
      createdAt: now,
      intent: "Summarize this conversation",
      targetLeaseID: UUID(),
      contextManifestID: UUID(),
      desiredOutcome: "A concise answer",
      allowedActions: [.read],
      approvalPolicy: .readOnly,
      deadline: now.addingTimeInterval(60)
    )
  }
}

private func assertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ errorHandler: (Error) -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected expression to throw", file: file, line: line)
  } catch {
    errorHandler(error)
  }
}
