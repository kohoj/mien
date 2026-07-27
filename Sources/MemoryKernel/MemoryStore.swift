import Foundation
import MienContracts

public enum MemoryNamespace: Codable, Equatable, Hashable, Sendable {
  case user
  case relationship(String)
  case conversation(String)
  case workspace(String)
  case application(String)
}

public enum MemoryStatus: String, Codable, Sendable {
  case candidate
  case approved
  case rejected
}

public struct MemoryClaim: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let namespace: MemoryNamespace
  public let claim: String
  public let sourceArtifactIDs: [UUID]
  public let confidence: Double
  public let sensitivity: Sensitivity
  public let status: MemoryStatus
  public let createdAt: Date
  public let lastUsedAt: Date?
  public let expiresAt: Date?
  public let supersedes: UUID?
  public let approvalReference: String?

  public init(
    id: UUID = UUID(),
    namespace: MemoryNamespace,
    claim: String,
    sourceArtifactIDs: [UUID],
    confidence: Double,
    sensitivity: Sensitivity,
    status: MemoryStatus,
    createdAt: Date,
    lastUsedAt: Date? = nil,
    expiresAt: Date? = nil,
    supersedes: UUID? = nil,
    approvalReference: String? = nil
  ) {
    self.id = id
    self.namespace = namespace
    self.claim = claim
    self.sourceArtifactIDs = sourceArtifactIDs
    self.confidence = confidence
    self.sensitivity = sensitivity
    self.status = status
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
    self.expiresAt = expiresAt
    self.supersedes = supersedes
    self.approvalReference = approvalReference
  }
}

public enum MemoryStoreError: Error, Equatable, Sendable {
  case emptyClaim
  case invalidConfidence
  case missingProvenance
  case secretMemoryForbidden
  case claimNotFound
  case approvalReferenceRequired
}

public actor MemoryStore {
  private var storage: [UUID: MemoryClaim] = [:]

  public init() {}

  @discardableResult
  public func propose(
    namespace: MemoryNamespace,
    claim: String,
    sourceArtifactIDs: [UUID],
    confidence: Double,
    sensitivity: Sensitivity,
    expiresAt: Date? = nil,
    supersedes: UUID? = nil,
    now: Date = Date()
  ) throws -> MemoryClaim {
    let claim = claim.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !claim.isEmpty else { throw MemoryStoreError.emptyClaim }
    guard (0...1).contains(confidence) else { throw MemoryStoreError.invalidConfidence }
    guard !sourceArtifactIDs.isEmpty else { throw MemoryStoreError.missingProvenance }
    guard sensitivity != .secret else { throw MemoryStoreError.secretMemoryForbidden }

    let record = MemoryClaim(
      namespace: namespace,
      claim: claim,
      sourceArtifactIDs: sourceArtifactIDs,
      confidence: confidence,
      sensitivity: sensitivity,
      status: .candidate,
      createdAt: now,
      expiresAt: expiresAt,
      supersedes: supersedes
    )
    storage[record.id] = record
    return record
  }

  @discardableResult
  public func approve(
    id: UUID,
    approvalReference: String,
    now: Date = Date()
  ) throws -> MemoryClaim {
    guard let record = storage[id] else { throw MemoryStoreError.claimNotFound }
    guard !approvalReference.isEmpty else {
      throw MemoryStoreError.approvalReferenceRequired
    }
    let approved = MemoryClaim(
      id: record.id,
      namespace: record.namespace,
      claim: record.claim,
      sourceArtifactIDs: record.sourceArtifactIDs,
      confidence: record.confidence,
      sensitivity: record.sensitivity,
      status: .approved,
      createdAt: record.createdAt,
      lastUsedAt: record.lastUsedAt,
      expiresAt: record.expiresAt,
      supersedes: record.supersedes,
      approvalReference: approvalReference
    )
    storage[id] = approved
    return approved
  }

  public func retrieve(
    namespace: MemoryNamespace,
    maximumSensitivity: Sensitivity,
    limit: Int,
    now: Date = Date()
  ) -> [MemoryClaim] {
    guard limit > 0 else { return [] }
    let superseded = Set(storage.values.compactMap(\.supersedes))
    return storage.values
      .filter {
        $0.namespace == namespace
          && $0.status == .approved
          && $0.sensitivity <= maximumSensitivity
          && ($0.expiresAt == nil || now < $0.expiresAt!)
          && !superseded.contains($0.id)
      }
      .sorted {
        if $0.confidence == $1.confidence { return $0.createdAt > $1.createdAt }
        return $0.confidence > $1.confidence
      }
      .prefix(limit)
      .map { $0 }
  }

  public func reject(id: UUID) throws {
    guard let record = storage[id] else { throw MemoryStoreError.claimNotFound }
    storage[id] = MemoryClaim(
      id: record.id,
      namespace: record.namespace,
      claim: record.claim,
      sourceArtifactIDs: record.sourceArtifactIDs,
      confidence: record.confidence,
      sensitivity: record.sensitivity,
      status: .rejected,
      createdAt: record.createdAt,
      lastUsedAt: record.lastUsedAt,
      expiresAt: record.expiresAt,
      supersedes: record.supersedes,
      approvalReference: record.approvalReference
    )
  }
}
