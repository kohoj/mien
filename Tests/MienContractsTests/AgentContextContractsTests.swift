import MienContracts
import XCTest

final class AgentContextContractsTests: XCTestCase {
  func testAgentCanExplicitlyChooseNoExternalContext() throws {
    let decision = AgentContextDecision.none()

    XCTAssertNoThrow(try decision.validate())
    XCTAssertEqual(decision.kind, .none)
    XCTAssertNil(decision.request)
  }

  func testContextDecisionOwnsExactlyOneCoherentRoute() {
    let request = AgentContextRequest(scope: .conversation, evidence: [.accessibility])

    XCTAssertNoThrow(try AgentContextDecision.request(request).validate())
    XCTAssertThrowsError(
      try AgentContextDecision(kind: .none, request: request).validate()
    )
    XCTAssertThrowsError(
      try AgentContextDecision(kind: .request).validate()
    )
  }

  func testAgentCanRequestAccessibilityAndCurrentFrameTogether() throws {
    let request = AgentContextRequest(
      scope: .window,
      evidence: [.accessibility, .currentFrame]
    )

    XCTAssertNoThrow(try request.validate())
  }

  func testVisualHistoryOwnsBoundedHistoryScope() {
    XCTAssertNoThrow(
      try AgentContextRequest(
        scope: .boundedHistory,
        evidence: [.accessibility, .visualHistory]
      ).validate()
    )
    XCTAssertThrowsError(
      try AgentContextRequest(
        scope: .conversation,
        evidence: [.visualHistory]
      ).validate()
    )
  }

  func testSupportedCatalogExposesOnlyValidChoicesFromAvailableEvidence() throws {
    let catalog = AgentContextRequest.supportedCatalog(
      availableEvidence: [.accessibility, .currentFrame]
    )

    XCTAssertTrue(
      catalog.contains(
        AgentContextRequest(scope: .semanticRegion, evidence: [.accessibility])
      )
    )
    XCTAssertTrue(
      catalog.contains(
        AgentContextRequest(
          scope: .window,
          evidence: [.accessibility, .currentFrame]
        )
      )
    )
    XCTAssertFalse(
      catalog.contains(
        AgentContextRequest(scope: .window, evidence: [.accessibility])
      )
    )
    XCTAssertTrue(catalog.allSatisfy { (try? $0.validate()) != nil })
  }

  func testCatalogMatchingTreatsEvidenceAsAnUnorderedSet() {
    let advertised = AgentContextRequest(
      scope: .window,
      evidence: [.accessibility, .currentFrame]
    )
    let selected = AgentContextRequest(
      scope: .window,
      evidence: [.currentFrame, .accessibility]
    )

    XCTAssertTrue(selected.matchesCatalogEntry(advertised))
  }

  func testAgentRequestRejectsDuplicatedAndConflictingEvidence() {
    XCTAssertThrowsError(
      try AgentContextRequest(
        scope: .window,
        evidence: [.currentFrame, .currentFrame]
      ).validate()
    )
    XCTAssertThrowsError(
      try AgentContextRequest(
        scope: .boundedHistory,
        evidence: [.currentFrame, .visualHistory]
      ).validate()
    )
  }

  func testOutcomeCarriesTypedPresentationWithoutParsingItsContent() throws {
    let outcome = AgentOutcome(kind: .draftProposal, content: "可以，明天下午见。")

    XCTAssertNoThrow(try outcome.validate())
    XCTAssertEqual(outcome.kind, .draftProposal)
    XCTAssertEqual(outcome.content, "可以，明天下午见。")
  }
}
