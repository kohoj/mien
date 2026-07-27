import ArtifactStore
import Foundation
import MienContracts
import XCTest

final class PrivateArtifactStoreTests: XCTestCase {
  func testInitializationReapsArtifactsLeftByAnInterruptedProcess() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let orphan = root.appendingPathComponent("orphan.partial")
    XCTAssertTrue(
      FileManager.default.createFile(atPath: orphan.path, contents: Data("secret".utf8)))
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try PrivateArtifactStore(rootURL: root)

    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
  }

  func testStoredArtifactsArePrivateImmutableAndTargetScoped() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PrivateArtifactStore(rootURL: root)
    let now = Date()
    let taskID = UUID()
    let leaseID = UUID()

    let artifact = try await store.store(
      Data("private context".utf8),
      descriptor: ArtifactDescriptor(
        taskID: taskID,
        targetLeaseID: leaseID,
        kind: .text,
        provider: .accessibility,
        providerVersion: "1",
        coherenceGroup: UUID(),
        scope: .conversation,
        mediaType: "text/plain",
        sourceTrust: .untrustedContent,
        sensitivity: .userContent,
        confidence: 1,
        complete: true,
        retention: ArtifactRetention(
          expiresAt: now.addingTimeInterval(30),
          deleteAfterTask: true,
          memoryEligible: false
        )
      ),
      now: now
    )

    let attributes = try FileManager.default.attributesOfItem(atPath: artifact.privateURI.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    XCTAssertEqual(artifact.taskID, taskID)
    XCTAssertEqual(artifact.targetLeaseID, leaseID)
    XCTAssertEqual(try Data(contentsOf: artifact.privateURI), Data("private context".utf8))
  }

  func testExpiredArtifactIsDeletedAndNoLongerResolvable() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PrivateArtifactStore(rootURL: root)
    let now = Date()
    let artifact = try await store.store(
      Data("context".utf8),
      descriptor: ArtifactDescriptor(
        taskID: UUID(),
        targetLeaseID: UUID(),
        kind: .text,
        provider: .selection,
        providerVersion: "1",
        coherenceGroup: UUID(),
        scope: .selection,
        mediaType: "text/plain",
        sourceTrust: .hostObserved,
        sensitivity: .userContent,
        confidence: 1,
        complete: true,
        retention: ArtifactRetention(
          expiresAt: now.addingTimeInterval(1),
          deleteAfterTask: true,
          memoryEligible: false
        )
      ),
      now: now
    )

    let removed = await store.purgeExpired(now: now.addingTimeInterval(2))
    XCTAssertEqual(removed, [artifact.id])
    XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.privateURI.path))
  }
}
