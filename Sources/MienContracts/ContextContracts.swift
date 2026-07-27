import Foundation

public enum ContextArtifactKind: String, Codable, CaseIterable, Sendable {
  case text
  case image
  case accessibilityTree
  case memory
  case resource
}

public enum ContextProviderKind: String, Codable, CaseIterable, Sendable {
  case selection
  case accessibility
  case screenCapture
  case longview
  case localOCR
  case nativeConnector
  case memory
  case visualFallback
}

public enum ContextScope: String, Codable, CaseIterable, Sendable {
  case selection
  case pointedElement
  case semanticRegion
  case conversation
  case window
  case boundedHistory
  case relatedMemory
  case multipleApplications

  /// Returns true only when this scope is a genuine coverage superset of `other`.
  /// Spatial, temporal, memory, and multi-application scopes are intentionally
  /// not forced into a single privilege order.
  public func encompasses(_ other: Self) -> Bool {
    lineage.contains(other)
  }

  public func coverageDepth(of other: Self) -> Int? {
    lineage.firstIndex(of: other)
  }

  public var requiresExtendedCaptureDeadline: Bool {
    switch self {
    case .boundedHistory, .relatedMemory, .multipleApplications: true
    default: false
    }
  }

  public var requestsConversationSemantics: Bool {
    switch self {
    case .conversation, .boundedHistory: true
    default: false
    }
  }

  private var lineage: [Self] {
    switch self {
    case .selection: [.selection]
    case .pointedElement: [.selection, .pointedElement]
    case .semanticRegion: [.selection, .pointedElement, .semanticRegion]
    case .conversation: [.selection, .pointedElement, .semanticRegion, .conversation]
    case .window: [.selection, .pointedElement, .semanticRegion, .window]
    case .boundedHistory:
      [.selection, .pointedElement, .semanticRegion, .conversation, .boundedHistory]
    case .relatedMemory: [.relatedMemory]
    case .multipleApplications: [.multipleApplications]
    }
  }
}

public enum Sensitivity: String, Codable, Comparable, Sendable {
  case publicData
  case userContent
  case sensitive
  case secret

  private var rank: Int {
    switch self {
    case .publicData: 0
    case .userContent: 1
    case .sensitive: 2
    case .secret: 3
    }
  }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public enum SourceTrust: String, Codable, Sendable {
  case hostObserved
  case connectorVerified
  case untrustedContent
  case modelDerived
}

public struct ArtifactRetention: Codable, Equatable, Hashable, Sendable {
  public let expiresAt: Date
  public let deleteAfterTask: Bool
  public let memoryEligible: Bool

  public init(expiresAt: Date, deleteAfterTask: Bool, memoryEligible: Bool) {
    self.expiresAt = expiresAt
    self.deleteAfterTask = deleteAfterTask
    self.memoryEligible = memoryEligible
  }
}

public struct ContextArtifact: Codable, Equatable, Hashable, Sendable, Identifiable,
  ContractValidating
{
  public let id: UUID
  public let taskID: UUID
  public let targetLeaseID: UUID
  public let kind: ContextArtifactKind
  public let provider: ContextProviderKind
  public let providerVersion: String
  public let capturedAt: Date
  public let coherenceGroup: UUID
  public let scope: ContextScope
  public let mediaType: String
  public let privateURI: URL
  public let byteCount: Int
  public let contentDigest: String
  public let sourceTrust: SourceTrust
  public let sensitivity: Sensitivity
  public let confidence: Double
  public let complete: Bool
  public let retention: ArtifactRetention

  public init(
    id: UUID = UUID(),
    taskID: UUID,
    targetLeaseID: UUID,
    kind: ContextArtifactKind,
    provider: ContextProviderKind,
    providerVersion: String,
    capturedAt: Date,
    coherenceGroup: UUID,
    scope: ContextScope,
    mediaType: String,
    privateURI: URL,
    byteCount: Int = 0,
    contentDigest: String,
    sourceTrust: SourceTrust,
    sensitivity: Sensitivity,
    confidence: Double,
    complete: Bool,
    retention: ArtifactRetention
  ) {
    self.id = id
    self.taskID = taskID
    self.targetLeaseID = targetLeaseID
    self.kind = kind
    self.provider = provider
    self.providerVersion = providerVersion
    self.capturedAt = capturedAt
    self.coherenceGroup = coherenceGroup
    self.scope = scope
    self.mediaType = mediaType
    self.privateURI = privateURI
    self.byteCount = byteCount
    self.contentDigest = contentDigest
    self.sourceTrust = sourceTrust
    self.sensitivity = sensitivity
    self.confidence = confidence
    self.complete = complete
    self.retention = retention
  }

  public func validate(now: Date) throws {
    guard !providerVersion.isEmpty else {
      throw ContractValidationError.empty("artifact.providerVersion")
    }
    guard !mediaType.isEmpty else {
      throw ContractValidationError.empty("artifact.mediaType")
    }
    guard privateURI.isFileURL else {
      throw ContractValidationError.invalid("artifact.privateURI")
    }
    guard byteCount >= 0 else {
      throw ContractValidationError.invalid("artifact.byteCount")
    }
    let digest = contentDigest.lowercased()
    guard digest.count == 64,
      digest.allSatisfy({ $0.isHexDigit })
    else {
      throw ContractValidationError.invalid("artifact.contentDigest")
    }
    guard (0...1).contains(confidence) else {
      throw ContractValidationError.invalid("artifact.confidence")
    }
    guard now < retention.expiresAt else {
      throw ContractValidationError.expired("artifact.retention")
    }
    guard sensitivity != .secret else {
      throw ContractValidationError.unauthorized("secret content cannot become an artifact")
    }
  }
}

public struct ContextBudget: Codable, Equatable, Hashable, Sendable {
  public let maximumArtifacts: Int
  public let maximumBytes: Int
  public let maximumTextCharacters: Int
  public let deadline: Date

  public init(
    maximumArtifacts: Int,
    maximumBytes: Int,
    maximumTextCharacters: Int,
    deadline: Date
  ) {
    self.maximumArtifacts = maximumArtifacts
    self.maximumBytes = maximumBytes
    self.maximumTextCharacters = maximumTextCharacters
    self.deadline = deadline
  }
}

public struct ContextManifest: Codable, Equatable, Hashable, Sendable, Identifiable,
  ContractValidating
{
  public let id: UUID
  public let taskID: UUID
  public let targetLeaseID: UUID
  public let requestedScope: ContextScope
  public let resolvedScope: ContextScope
  public let artifacts: [ContextArtifact]
  public let acquisitionReceiptIDs: [UUID]
  public let omittedScopes: [ContextScope: String]
  public let budget: ContextBudget
  public let remoteTransmissionAllowed: Bool
  public let coherent: Bool
  public let digest: String

  public init(
    id: UUID = UUID(),
    taskID: UUID,
    targetLeaseID: UUID,
    requestedScope: ContextScope,
    resolvedScope: ContextScope,
    artifacts: [ContextArtifact],
    acquisitionReceiptIDs: [UUID] = [],
    omittedScopes: [ContextScope: String],
    budget: ContextBudget,
    remoteTransmissionAllowed: Bool,
    coherent: Bool,
    digest: String
  ) {
    self.id = id
    self.taskID = taskID
    self.targetLeaseID = targetLeaseID
    self.requestedScope = requestedScope
    self.resolvedScope = resolvedScope
    self.artifacts = artifacts
    self.acquisitionReceiptIDs = acquisitionReceiptIDs
    self.omittedScopes = omittedScopes
    self.budget = budget
    self.remoteTransmissionAllowed = remoteTransmissionAllowed
    self.coherent = coherent
    self.digest = digest
  }

  public func validate(now: Date) throws {
    guard budget.maximumArtifacts > 0,
      budget.maximumBytes > 0,
      budget.maximumTextCharacters >= 0,
      now < budget.deadline
    else {
      throw ContractValidationError.invalid("manifest.budget")
    }
    guard artifacts.count <= budget.maximumArtifacts else {
      throw ContractValidationError.inconsistent("artifact budget exceeded")
    }
    guard artifacts.reduce(0, { $0 + $1.byteCount }) <= budget.maximumBytes else {
      throw ContractValidationError.inconsistent("artifact byte budget exceeded")
    }
    guard Set(artifacts.map(\.id)).count == artifacts.count else {
      throw ContractValidationError.inconsistent("duplicate artifact IDs")
    }
    guard Set(acquisitionReceiptIDs).count == acquisitionReceiptIDs.count else {
      throw ContractValidationError.inconsistent("duplicate acquisition receipt IDs")
    }
    for artifact in artifacts {
      try artifact.validate(now: now)
      guard artifact.taskID == taskID, artifact.targetLeaseID == targetLeaseID else {
        throw ContractValidationError.inconsistent("artifact escaped task or target lease")
      }
      if remoteTransmissionAllowed, artifact.sensitivity >= .sensitive {
        throw ContractValidationError.unauthorized(
          "sensitive artifact cannot cross the local trust boundary"
        )
      }
    }
    guard requestedScope.encompasses(resolvedScope) else {
      throw ContractValidationError.inconsistent("resolved scope escaped the requested coverage")
    }
    guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else {
      throw ContractValidationError.invalid("manifest.digest")
    }
  }
}
