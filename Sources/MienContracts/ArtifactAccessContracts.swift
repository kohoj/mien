import Foundation

/// The only capability that may turn an artifact reference back into bytes.
/// Consumers receive an opaque artifact identity and cannot choose a filesystem path.
public protocol ContextArtifactReading: Sendable {
  func readArtifact(
    id: UUID,
    taskID: UUID,
    targetLeaseID: UUID,
    now: Date
  ) async throws -> Data
}
