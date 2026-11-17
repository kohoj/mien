import ArtifactStore
import ContextKernel
import Foundation
import MienContracts

public struct LongviewContextProvider: ContextProvider {
  public let kind: ContextProviderKind = .longview

  private let adapter: LongviewAdapter
  private let store: PrivateArtifactStore
  private let temporaryRoot: URL

  public init(
    executableURL: URL,
    store: PrivateArtifactStore,
    temporaryRoot: URL
  ) throws {
    adapter = try LongviewAdapter(executableURL: executableURL)
    self.store = store
    self.temporaryRoot = temporaryRoot
  }

  public func probe(target: TargetLease) async -> ProviderCapability {
    ProviderCapability(
      available: (try? target.validate(now: Date())) != nil,
      maximumScope: .boundedHistory,
      estimatedLatencyMilliseconds: 1_800,
      reason: "Longview bounded capture is available"
    )
  }

  public func capture(_ request: ContextCaptureRequest) async throws -> ContextCaptureOutcome {
    try WindowLeaseValidator().validate(request.target.window)
    let directory =
      temporaryRoot
      .appendingPathComponent(request.taskID.uuidString, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let outputURL = directory.appendingPathComponent("context.png")
    let maximumFrames: Int
    switch request.requestedScope {
    case .boundedHistory, .relatedMemory, .multipleApplications: maximumFrames = 24
    case .conversation: maximumFrames = 10
    default: maximumFrames = 1
    }
    let outcome = try await adapter.capture(
      LongviewCaptureRequest(
        taskID: request.taskID,
        target: request.target,
        outputURL: outputURL,
        maximumFrames: maximumFrames,
        // Visual history means content preceding the current viewport. Chat
        // windows normally open at the newest message, so scrolling down ends
        // immediately and Longview cannot establish an overlap. The direction
        // is part of the typed evidence contract, not an inference from prose.
        direction: maximumFrames > 1 ? .up : .down,
        // Several applications — WeChat among them — expose no background
        // scroll route at all, so `background-only` fails outright with
        // `background_scroll_unavailable`. `background-first` still prefers the
        // background route and only activates the window when that route is
        // unavailable; the adapter then refuses the capture unless Longview
        // verifies that focus, viewport, and pointer were all restored.
        focusPolicy: .backgroundFirst
      ))
    let data = try Data(contentsOf: outputURL, options: [.mappedIfSafe])
    guard data.count <= request.budget.maximumBytes else {
      throw LongviewAdapterError.invalidRequest("captured image exceeded the context budget")
    }
    let artifact = try await store.store(
      data,
      descriptor: ArtifactDescriptor(
        taskID: request.taskID,
        targetLeaseID: request.target.id,
        kind: .image,
        provider: .longview,
        providerVersion: "schema-v2",
        coherenceGroup: request.coherenceGroup,
        scope: outcome.artifact.scope,
        mediaType: "image/png",
        sourceTrust: .untrustedContent,
        sensitivity: .userContent,
        confidence: 1,
        complete: outcome.artifact.complete,
        retention: ArtifactRetention(
          expiresAt: min(
            request.target.expiresAt,
            Date().addingTimeInterval(300)
          ),
          deleteAfterTask: true,
          memoryEligible: false
        )
      )
    )
    let receipt = MutationReceipt(
      taskID: request.taskID,
      targetLeaseID: request.target.id,
      action: .read,
      executor: "LongviewAdapter",
      route: outcome.receipt.route,
      beforeEvidenceArtifactIDs: outcome.receipt.beforeEvidenceArtifactIDs,
      postcondition: .verified(evidenceArtifactIDs: [artifact.id]),
      inverseOperationReference: outcome.receipt.inverseOperationReference,
      recovery: outcome.receipt.recovery,
      completedAt: outcome.receipt.completedAt
    )
    return ContextCaptureOutcome(artifacts: [artifact], receipts: [receipt])
  }
}
