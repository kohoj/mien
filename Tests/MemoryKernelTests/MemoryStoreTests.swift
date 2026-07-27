import Foundation
import MemoryKernel
import MienContracts
import XCTest

final class MemoryStoreTests: XCTestCase {
  func testModelProposalNeverBecomesRetrievableMemoryWithoutApproval() async throws {
    let store = MemoryStore()
    let proposed = try await store.propose(
      namespace: .relationship("lin"),
      claim: "Prefers concise replies",
      sourceArtifactIDs: [UUID()],
      confidence: 0.8,
      sensitivity: .userContent
    )

    XCTAssertEqual(proposed.status, .candidate)
    let beforeApproval = await store.retrieve(
      namespace: .relationship("lin"),
      maximumSensitivity: .userContent,
      limit: 10
    )
    XCTAssertTrue(beforeApproval.isEmpty)

    _ = try await store.approve(id: proposed.id, approvalReference: "user:memory-review")
    let retrieved = await store.retrieve(
      namespace: .relationship("lin"),
      maximumSensitivity: .userContent,
      limit: 10
    )
    XCTAssertEqual(retrieved.map(\.id), [proposed.id])
  }

  func testNewApprovedClaimCanSupersedeOldClaimWithoutDeletingProvenance() async throws {
    let store = MemoryStore()
    let old = try await store.propose(
      namespace: .user,
      claim: "Prefers long replies",
      sourceArtifactIDs: [UUID()],
      confidence: 0.7,
      sensitivity: .userContent
    )
    _ = try await store.approve(id: old.id, approvalReference: "user:1")
    let replacement = try await store.propose(
      namespace: .user,
      claim: "Prefers concise replies",
      sourceArtifactIDs: [UUID()],
      confidence: 0.9,
      sensitivity: .userContent,
      supersedes: old.id
    )
    _ = try await store.approve(id: replacement.id, approvalReference: "user:2")

    let retrieved = await store.retrieve(
      namespace: .user,
      maximumSensitivity: .userContent,
      limit: 10
    )
    XCTAssertEqual(retrieved.map(\.id), [replacement.id])
  }
}
