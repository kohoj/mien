import Foundation
import MienContracts
import XCTest

final class ContextScopeLatticeTests: XCTestCase {
  /// Scopes that a provider reading only the accessibility tree can produce.
  /// `SelectionContextProvider` emits `.selection`; `AccessibilityContextProvider`
  /// emits `.pointedElement`, `.semanticRegion`, or `.conversation`.
  private static let accessibilityReachableScopes: [ContextScope] = [
    .selection, .pointedElement, .semanticRegion, .conversation,
  ]

  func testPixelCaptureIsRequiredExactlyForScopesNoAccessibilityProviderEmits() {
    XCTAssertTrue(ContextScope.window.requiresPixelCapture)
    XCTAssertTrue(ContextScope.boundedHistory.requiresPixelCapture)
    XCTAssertTrue(ContextScope.multipleApplications.requiresPixelCapture)
    XCTAssertFalse(ContextScope.selection.requiresPixelCapture)
    XCTAssertFalse(ContextScope.pointedElement.requiresPixelCapture)
    XCTAssertFalse(ContextScope.semanticRegion.requiresPixelCapture)
    XCTAssertFalse(ContextScope.conversation.requiresPixelCapture)
    XCTAssertFalse(ContextScope.relatedMemory.requiresPixelCapture)
  }

  /// Guards the invariant behind `requiresPixelCapture`: a scope that claims not
  /// to need pixels must itself be a scope an accessibility provider emits, not
  /// merely one that encompasses such a scope. `.window` encompasses
  /// `.semanticRegion`, so the broker would admit an accessibility artifact
  /// against a `.window` request — but `resolvedScope` could never reach
  /// `.window`, and the task would degrade with no way to recover. That is the
  /// failure this project shipped with. `.relatedMemory` is exempt because the
  /// memory provider, not a desktop provider, satisfies it.
  func testEveryNonPixelScopeIsItselfAccessibilityReachable() {
    for scope in ContextScope.allCases
    where !scope.requiresPixelCapture && scope != .relatedMemory {
      XCTAssertTrue(
        Self.accessibilityReachableScopes.contains(scope),
        "\(scope) claims to need no pixels yet no accessibility provider emits it"
      )
    }
  }

  func testWindowAndConversationAreSiblingsRatherThanOrdered() {
    XCTAssertFalse(ContextScope.window.encompasses(.conversation))
    XCTAssertFalse(ContextScope.conversation.encompasses(.window))
  }

  func testConversationEncompassesEveryNarrowerSpatialScope() {
    XCTAssertTrue(ContextScope.conversation.encompasses(.selection))
    XCTAssertTrue(ContextScope.conversation.encompasses(.pointedElement))
    XCTAssertTrue(ContextScope.conversation.encompasses(.semanticRegion))
    XCTAssertTrue(ContextScope.conversation.encompasses(.conversation))
  }

  func testExtendedCaptureDeadlineIsReservedForScopesWithRealAcquisitionCost() {
    XCTAssertFalse(ContextScope.conversation.requiresExtendedCaptureDeadline)
    XCTAssertTrue(ContextScope.boundedHistory.requiresExtendedCaptureDeadline)
  }
}
