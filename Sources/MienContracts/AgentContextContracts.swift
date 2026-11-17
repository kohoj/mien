import Foundation

/// Evidence classes visible to the Agent. These describe information, not the
/// platform adapter that happens to acquire it.
public enum AgentEvidenceKind: String, Codable, CaseIterable, Hashable, Sendable {
  case selectedText
  case accessibility
  case currentFrame
  case visualHistory
}

/// The Agent's complete context decision for one task. The Host decodes and
/// validates this envelope but never derives it from the wording of user input.
public struct AgentContextRequest: Codable, Equatable, Hashable, Sendable,
  ContractValidating
{
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let scope: ContextScope
  public let evidence: [AgentEvidenceKind]

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    scope: ContextScope,
    evidence: [AgentEvidenceKind]
  ) {
    self.schemaVersion = schemaVersion
    self.scope = scope
    self.evidence = evidence
  }

  public func validate(now: Date = Date()) throws {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw ContractValidationError.invalid("agentContextRequest.schemaVersion")
    }
    guard !evidence.isEmpty else {
      throw ContractValidationError.empty("agentContextRequest.evidence")
    }
    guard evidence.count <= 3, Set(evidence).count == evidence.count else {
      throw ContractValidationError.invalid("agentContextRequest.evidence")
    }
    guard !(evidence.contains(.currentFrame) && evidence.contains(.visualHistory)) else {
      throw ContractValidationError.inconsistent(
        "current frame and visual history are mutually exclusive"
      )
    }
    if evidence.contains(.currentFrame), scope != .window {
      throw ContractValidationError.inconsistent("current frame requires window scope")
    }
    if evidence.contains(.visualHistory), scope != .boundedHistory {
      throw ContractValidationError.inconsistent("visual history requires bounded history scope")
    }
    if scope == .window, !evidence.contains(.currentFrame) {
      throw ContractValidationError.inconsistent("window scope requires current frame evidence")
    }
    if scope == .boundedHistory, !evidence.contains(.visualHistory) {
      throw ContractValidationError.inconsistent(
        "bounded history scope requires visual history evidence"
      )
    }
    if scope == .relatedMemory || scope == .multipleApplications {
      throw ContractValidationError.unauthorized("unsupported context authority expansion")
    }
  }

  /// Finite protocol surface the Host may advertise to an Agent. The catalog
  /// is derived only from available evidence classes; it contains no user
  /// semantics and gives the Agent valid choices instead of hidden rules.
  public static func supportedCatalog(
    availableEvidence: Set<AgentEvidenceKind>
  ) -> [Self] {
    var catalog: [Self] = []
    let hasSelection = availableEvidence.contains(.selectedText)
    let hasAccessibility = availableEvidence.contains(.accessibility)

    if hasSelection {
      catalog.append(Self(scope: .selection, evidence: [.selectedText]))
    }
    if hasAccessibility {
      catalog.append(Self(scope: .pointedElement, evidence: [.accessibility]))
      catalog.append(Self(scope: .semanticRegion, evidence: [.accessibility]))
      catalog.append(Self(scope: .conversation, evidence: [.accessibility]))
    }
    if hasSelection, hasAccessibility {
      catalog.append(
        Self(scope: .semanticRegion, evidence: [.selectedText, .accessibility])
      )
      catalog.append(
        Self(scope: .conversation, evidence: [.selectedText, .accessibility])
      )
    }
    appendVisualRequests(
      visual: .currentFrame,
      scope: .window,
      hasSelection: hasSelection,
      hasAccessibility: hasAccessibility,
      to: &catalog
    )
    appendVisualRequests(
      visual: .visualHistory,
      scope: .boundedHistory,
      hasSelection: hasSelection,
      hasAccessibility: hasAccessibility,
      to: &catalog
    )
    return catalog.filter { request in
      Set(request.evidence).isSubset(of: availableEvidence)
        && (try? request.validate()) != nil
    }
  }

  public func matchesCatalogEntry(_ other: Self) -> Bool {
    schemaVersion == other.schemaVersion
      && scope == other.scope
      && Set(evidence) == Set(other.evidence)
  }

  private static func appendVisualRequests(
    visual: AgentEvidenceKind,
    scope: ContextScope,
    hasSelection: Bool,
    hasAccessibility: Bool,
    to catalog: inout [Self]
  ) {
    catalog.append(Self(scope: scope, evidence: [visual]))
    if hasAccessibility {
      catalog.append(Self(scope: scope, evidence: [.accessibility, visual]))
    }
    if hasSelection {
      catalog.append(Self(scope: scope, evidence: [.selectedText, visual]))
    }
    if hasSelection, hasAccessibility {
      catalog.append(
        Self(scope: scope, evidence: [.selectedText, .accessibility, visual])
      )
    }
  }
}

public enum AgentContextDecisionKind: String, Codable, CaseIterable, Sendable {
  /// The Agent can satisfy this turn from the verbatim user input and the
  /// conversation it already owns. The Host acquires and transmits no evidence.
  case none

  /// The Agent selected one exact request from the Host-advertised catalog.
  case request
}

/// The Agent's mandatory first protocol decision for every user turn.
///
/// `none` is deliberately explicit rather than inferred by Host code. This
/// keeps ordinary conversation and evidence-backed work on one typed path while
/// preserving the invariant that only the Agent interprets user input.
public struct AgentContextDecision: Codable, Equatable, Sendable, ContractValidating {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let kind: AgentContextDecisionKind
  public let request: AgentContextRequest?

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    kind: AgentContextDecisionKind,
    request: AgentContextRequest? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.kind = kind
    self.request = request
  }

  public static func none() -> Self {
    Self(kind: .none)
  }

  public static func request(_ request: AgentContextRequest) -> Self {
    Self(kind: .request, request: request)
  }

  public func validate(now: Date = Date()) throws {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw ContractValidationError.invalid("agentContextDecision.schemaVersion")
    }
    switch (kind, request) {
    case (.none, nil):
      return
    case (.request, .some(let request)):
      try request.validate(now: now)
    case (.none, .some):
      throw ContractValidationError.inconsistent(
        "a no-context decision cannot carry a request"
      )
    case (.request, nil):
      throw ContractValidationError.empty("agentContextDecision.request")
    }
  }
}

public enum AgentOutcomeKind: String, Codable, CaseIterable, Sendable {
  case answer
  case draftProposal
}

/// A typed proposal from the Agent. `content` is never interpreted by Host
/// code; only `kind` selects the already-authorized presentation path.
public struct AgentOutcome: Codable, Equatable, Sendable, ContractValidating {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let kind: AgentOutcomeKind
  public let content: String

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    kind: AgentOutcomeKind,
    content: String
  ) {
    self.schemaVersion = schemaVersion
    self.kind = kind
    self.content = content
  }

  public func validate(now: Date = Date()) throws {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw ContractValidationError.invalid("agentOutcome.schemaVersion")
    }
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ContractValidationError.empty("agentOutcome.content")
    }
  }
}
