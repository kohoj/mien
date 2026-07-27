import ActionKernel
import Foundation
import MienContracts
import XCTest

@testable import DesktopActionAdapters

final class AXDraftExecutorTests: XCTestCase {
  func testInsertUsesCompareAndSwapAndUndoRestoresOriginalState() async throws {
    let now = Date()
    let driver = StubDraftDriver(
      state: DraftFieldState(
        value: "Hello",
        selection: DraftSelection(location: 5, length: 0)
      )
    )
    let executor = AXDraftExecutor(driver: driver, undoDuration: 60)
    let taskID = UUID()
    let proposal = try await executor.prepare(
      taskID: taskID,
      window: makeWindow(now: now),
      element: makeElement(),
      scope: .pointedElement,
      draft: " world",
      now: now
    )

    let receipt = try await executor.execute(proposal)

    XCTAssertTrue(receipt.isVerifiedSuccess)
    let inserted = await driver.current()
    XCTAssertEqual(
      inserted,
      DraftFieldState(
        value: "Hello world",
        selection: DraftSelection(location: 11, length: 0)
      ))
    let reference = try XCTUnwrap(receipt.inverseOperationReference)

    let undo = try await executor.undo(reference: reference, taskID: taskID, now: now)

    XCTAssertTrue(undo.receipt.isVerifiedSuccess)
    let restored = await driver.current()
    XCTAssertEqual(
      restored,
      DraftFieldState(
        value: "Hello",
        selection: DraftSelection(location: 5, length: 0)
      ))
  }

  func testStalePreconditionNeverOverwritesUserInput() async throws {
    let now = Date()
    let driver = StubDraftDriver(
      state: DraftFieldState(
        value: "",
        selection: DraftSelection(location: 0, length: 0)
      )
    )
    let executor = AXDraftExecutor(driver: driver)
    let proposal = try await executor.prepare(
      taskID: UUID(),
      window: makeWindow(now: now),
      element: makeElement(),
      scope: .pointedElement,
      draft: "assistant draft",
      now: now
    )
    await driver.replaceState(
      DraftFieldState(value: "user typed", selection: DraftSelection(location: 10, length: 0))
    )

    do {
      _ = try await executor.execute(proposal)
      XCTFail("Expected stale compare-and-swap precondition")
    } catch {
      XCTAssertEqual(error as? DraftMutationError, .stalePrecondition)
    }
    let preserved = await driver.current()
    XCTAssertEqual(preserved.value, "user typed")
  }

  func testNonemptyFieldWithoutCaretIsNeverDestroyed() async throws {
    let now = Date()
    let driver = StubDraftDriver(state: DraftFieldState(value: "keep me", selection: nil))
    let executor = AXDraftExecutor(driver: driver)

    do {
      _ = try await executor.prepare(
        taskID: UUID(),
        window: makeWindow(now: now),
        element: makeElement(),
        scope: .pointedElement,
        draft: "replacement",
        now: now
      )
      XCTFail("Expected missing-caret refusal")
    } catch {
      XCTAssertEqual(error as? DraftMutationError, .selectionUnavailable)
    }
    let preserved = await driver.current()
    XCTAssertEqual(preserved.value, "keep me")
  }

  func testVerificationFailureRollsBackBeforeReturningReceipt() async throws {
    let now = Date()
    let original = DraftFieldState(
      value: "before",
      selection: DraftSelection(location: 6, length: 0)
    )
    let driver = StubDraftDriver(state: original, corruptNextWrite: true)
    let executor = AXDraftExecutor(driver: driver)
    let proposal = try await executor.prepare(
      taskID: UUID(),
      window: makeWindow(now: now),
      element: makeElement(),
      scope: .pointedElement,
      draft: " after",
      now: now
    )

    let receipt = try await executor.execute(proposal)

    XCTAssertFalse(receipt.isVerifiedSuccess)
    XCTAssertNil(receipt.inverseOperationReference)
    let restored = await driver.current()
    XCTAssertEqual(restored, original)
  }

  func testUndoRefusesToOverwriteSubsequentUserInput() async throws {
    let now = Date()
    let driver = StubDraftDriver(
      state: DraftFieldState(value: "", selection: DraftSelection(location: 0, length: 0))
    )
    let executor = AXDraftExecutor(driver: driver, undoDuration: 60)
    let taskID = UUID()
    let proposal = try await executor.prepare(
      taskID: taskID,
      window: makeWindow(now: now),
      element: makeElement(),
      scope: .pointedElement,
      draft: "assistant draft",
      now: now
    )
    let receipt = try await executor.execute(proposal)
    let reference = try XCTUnwrap(receipt.inverseOperationReference)
    await driver.replaceState(
      DraftFieldState(
        value: "assistant draft + user",
        selection: DraftSelection(location: 22, length: 0)
      )
    )

    do {
      _ = try await executor.undo(reference: reference, taskID: taskID, now: now)
      XCTFail("Expected undo compare-and-swap refusal")
    } catch {
      XCTAssertEqual(error as? DraftMutationError, .undoPreconditionChanged)
    }
    let preserved = await driver.current()
    XCTAssertEqual(preserved.value, "assistant draft + user")
  }

  private func makeWindow(now: Date) -> WindowLease {
    WindowLease(
      processIdentifier: 42,
      windowID: 9,
      bundleIdentifier: "com.example.editor",
      frame: ScreenRect(x: 10, y: 20, width: 800, height: 600),
      capturedAt: now,
      expiresAt: now.addingTimeInterval(120),
      userInputEpoch: 7
    )
  }

  private func makeElement() -> AXElementFingerprint {
    AXElementFingerprint(
      role: "AXTextArea",
      identifier: "composer",
      frame: ScreenRect(x: 100, y: 500, width: 500, height: 80)
    )
  }
}

private actor StubDraftDriver: DraftMutationDriving {
  private var state: DraftFieldState
  private var corruptNextWrite: Bool
  private var activeHandle: UUID?

  init(state: DraftFieldState, corruptNextWrite: Bool = false) {
    self.state = state
    self.corruptNextWrite = corruptNextWrite
  }

  func bind(
    window: WindowLease,
    element: AXElementFingerprint,
    now: Date,
    leaseDuration: TimeInterval
  ) async throws -> BoundDraftField {
    if state.selection == nil, !state.value.isEmpty {
      throw DraftMutationError.selectionUnavailable
    }
    let duration = max(leaseDuration, 2)
    let freshWindow = WindowLease(
      processIdentifier: window.processIdentifier,
      windowID: window.windowID,
      bundleIdentifier: window.bundleIdentifier,
      frame: window.frame,
      capturedAt: now,
      expiresAt: now.addingTimeInterval(duration),
      userInputEpoch: window.userInputEpoch
    )
    let target = TargetLease(
      invocationSnapshotID: UUID(),
      window: freshWindow,
      semanticTarget: element,
      issuedAt: now,
      expiresAt: now.addingTimeInterval(duration)
    )
    let handle = UUID()
    activeHandle = handle
    return BoundDraftField(handle: handle, target: target, state: state)
  }

  func read(handle: UUID, target: TargetLease, now: Date) async throws -> DraftFieldState {
    guard handle == activeHandle else { throw DraftMutationError.targetChanged }
    return state
  }

  func write(
    _ state: DraftFieldState,
    handle: UUID,
    target: TargetLease,
    now: Date
  ) async throws {
    guard handle == activeHandle else { throw DraftMutationError.targetChanged }
    if corruptNextWrite {
      corruptNextWrite = false
      self.state = DraftFieldState(value: state.value + "!", selection: state.selection)
    } else {
      self.state = state
    }
  }

  func release(handle: UUID) async {
    if activeHandle == handle { activeHandle = nil }
  }

  func replaceState(_ state: DraftFieldState) {
    self.state = state
  }

  func current() -> DraftFieldState { state }
}
