import Foundation
import MienContracts

public struct ContextCaptureRequest: Sendable {
  public let taskID: UUID
  public let target: TargetLease
  public let requestedScope: ContextScope
  public let budget: ContextBudget
  public let coherenceGroup: UUID
  /// Provider classes explicitly selected by the Agent through evidence
  /// contracts. An empty set preserves the broker's minimum-provider behavior
  /// for callers that do not require a multimodal bundle.
  public let requiredProviders: Set<ContextProviderKind>

  public init(
    taskID: UUID,
    target: TargetLease,
    requestedScope: ContextScope,
    budget: ContextBudget,
    coherenceGroup: UUID = UUID(),
    requiredProviders: Set<ContextProviderKind> = []
  ) {
    self.taskID = taskID
    self.target = target
    self.requestedScope = requestedScope
    self.budget = budget
    self.coherenceGroup = coherenceGroup
    self.requiredProviders = requiredProviders
  }
}

public struct ProviderCapability: Equatable, Sendable {
  public let available: Bool
  public let maximumScope: ContextScope
  public let estimatedLatencyMilliseconds: Int
  public let reason: String

  public init(
    available: Bool,
    maximumScope: ContextScope,
    estimatedLatencyMilliseconds: Int,
    reason: String
  ) {
    self.available = available
    self.maximumScope = maximumScope
    self.estimatedLatencyMilliseconds = estimatedLatencyMilliseconds
    self.reason = reason
  }
}

public protocol ContextProvider: Sendable {
  var kind: ContextProviderKind { get }
  func probe(target: TargetLease) async -> ProviderCapability
  func capture(_ request: ContextCaptureRequest) async throws -> ContextCaptureOutcome
}

public struct ContextCaptureOutcome: Sendable {
  public let artifacts: [ContextArtifact]
  public let receipts: [MutationReceipt]

  public init(artifacts: [ContextArtifact], receipts: [MutationReceipt] = []) {
    self.artifacts = artifacts
    self.receipts = receipts
  }
}

public struct ContextResolution: Sendable {
  public let artifacts: [ContextArtifact]
  public let receipts: [MutationReceipt]
  public let resolvedScope: ContextScope?
  public let omissions: [ContextProviderKind: String]
  public let exhaustedBudget: Bool

  public init(
    artifacts: [ContextArtifact],
    receipts: [MutationReceipt] = [],
    resolvedScope: ContextScope?,
    omissions: [ContextProviderKind: String],
    exhaustedBudget: Bool
  ) {
    self.artifacts = artifacts
    self.receipts = receipts
    self.resolvedScope = resolvedScope
    self.omissions = omissions
    self.exhaustedBudget = exhaustedBudget
  }
}

public actor ContextBroker {
  private enum DeadlineError: Error {
    case exceeded
  }

  private let providers: [any ContextProvider]

  public init(providers: [any ContextProvider]) {
    let rank = Dictionary(
      uniqueKeysWithValues: Self.providerOrder.enumerated().map {
        ($0.element, $0.offset)
      })
    self.providers = providers.sorted {
      rank[$0.kind, default: Int.max] < rank[$1.kind, default: Int.max]
    }
  }

  public func resolve(_ request: ContextCaptureRequest, now: Date = Date()) async throws
    -> ContextResolution
  {
    guard now < request.budget.deadline else {
      return ContextResolution(
        artifacts: [],
        receipts: [],
        resolvedScope: nil,
        omissions: [:],
        exhaustedBudget: true
      )
    }

    var artifacts: [ContextArtifact] = []
    var receipts: [MutationReceipt] = []
    var omissions: [ContextProviderKind: String] = [:]
    var resolvedScope: ContextScope?
    var resolvedProviders: Set<ContextProviderKind> = []

    for provider in providers {
      try Task.checkCancellation()
      if artifacts.count >= request.budget.maximumArtifacts || Date() >= request.budget.deadline {
        break
      }

      let capability = await provider.probe(target: request.target)
      try Task.checkCancellation()
      guard capability.available else {
        omissions[provider.kind] = capability.reason
        continue
      }
      do {
        let outcome = try await Self.capture(
          provider: provider,
          request: request,
          deadline: request.budget.deadline
        )
        let remaining = request.budget.maximumArtifacts - artifacts.count
        var remainingBytes =
          request.budget.maximumBytes
          - artifacts.reduce(0) { $0 + $1.byteCount }
        var rejectionReasons: [String] = []
        let accepted = Array(outcome.artifacts.prefix(remaining)).filter { artifact in
          if artifact.byteCount > remainingBytes {
            rejectionReasons.append("artifact exceeded remaining byte budget")
            return false
          }
          if artifact.taskID != request.taskID {
            rejectionReasons.append("artifact task binding mismatch")
            return false
          }
          if artifact.targetLeaseID != request.target.id {
            rejectionReasons.append("artifact target binding mismatch")
            return false
          }
          if !request.requestedScope.encompasses(artifact.scope) {
            rejectionReasons.append(
              "artifact scope \(artifact.scope.rawValue) exceeded requested scope \(request.requestedScope.rawValue)"
            )
            return false
          }
          if artifact.coherenceGroup != request.coherenceGroup {
            rejectionReasons.append("artifact coherence mismatch")
            return false
          }
          guard (try? artifact.validate(now: Date())) != nil else {
            rejectionReasons.append("artifact contract validation failed")
            return false
          }
          remainingBytes -= artifact.byteCount
          return true
        }
        guard !accepted.isEmpty else {
          if outcome.artifacts.isEmpty {
            omissions[provider.kind] = "provider returned no artifacts"
          } else {
            let reasons = Array(Set(rejectionReasons)).sorted().joined(separator: ", ")
            omissions[provider.kind] =
              reasons.isEmpty
              ? "provider returned no valid artifacts"
              : "provider returned no valid artifacts (\(reasons))"
          }
          continue
        }
        let acceptedArtifactIDs = Set(accepted.map(\.id))
        let acceptedReceipts = outcome.receipts.filter { receipt in
          guard receipt.taskID == request.taskID,
            receipt.targetLeaseID == request.target.id,
            receipt.action == .read,
            receipt.isVerifiedSuccess,
            case .verified(let evidenceArtifactIDs) = receipt.postcondition
          else {
            return false
          }
          return !evidenceArtifactIDs.isEmpty
            && Set(evidenceArtifactIDs).isSubset(of: acceptedArtifactIDs)
        }
        guard acceptedReceipts.count == outcome.receipts.count else {
          omissions[provider.kind] = "provider returned an unverified acquisition receipt"
          continue
        }
        artifacts.append(contentsOf: accepted)
        receipts.append(contentsOf: acceptedReceipts)
        resolvedProviders.insert(provider.kind)
        if let maximum = accepted.map(\.scope).max(by: { lhs, rhs in
          request.requestedScope.coverageDepth(of: lhs) ?? -1
            < request.requestedScope.coverageDepth(of: rhs) ?? -1
        }) {
          if let current = resolvedScope {
            let currentDepth = request.requestedScope.coverageDepth(of: current) ?? -1
            let candidateDepth = request.requestedScope.coverageDepth(of: maximum) ?? -1
            if candidateDepth > currentDepth { resolvedScope = maximum }
          } else {
            resolvedScope = maximum
          }
        }
        if resolvedScope == request.requestedScope,
          request.requiredProviders.isSubset(of: resolvedProviders)
        {
          break
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        omissions[provider.kind] = String(describing: error)
      }
    }

    return ContextResolution(
      artifacts: artifacts,
      receipts: receipts,
      resolvedScope: resolvedScope,
      omissions: omissions,
      exhaustedBudget: artifacts.count >= request.budget.maximumArtifacts
        || artifacts.reduce(0, { $0 + $1.byteCount }) >= request.budget.maximumBytes
        || Date() >= request.budget.deadline
    )
  }

  public static let providerOrder: [ContextProviderKind] = [
    .selection,
    .accessibility,
    .nativeConnector,
    .screenCapture,
    .longview,
    .localOCR,
    .memory,
    .visualFallback,
  ]

  private static func capture(
    provider: any ContextProvider,
    request: ContextCaptureRequest,
    deadline: Date
  ) async throws -> ContextCaptureOutcome {
    let remaining = deadline.timeIntervalSinceNow
    guard remaining > 0 else { throw DeadlineError.exceeded }
    return try await withThrowingTaskGroup(of: ContextCaptureOutcome.self) { group in
      group.addTask { try await provider.capture(request) }
      group.addTask {
        try await Task.sleep(for: .seconds(remaining))
        throw DeadlineError.exceeded
      }
      defer { group.cancelAll() }
      guard let first = try await group.next() else { throw DeadlineError.exceeded }
      return first
    }
  }
}
