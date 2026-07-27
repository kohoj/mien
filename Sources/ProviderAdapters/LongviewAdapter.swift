import CryptoKit
import Foundation
import MienContracts

public enum LongviewFocusPolicy: String, Codable, Sendable {
  case backgroundOnly = "background-only"
  case backgroundFirst = "background-first"
  case foreground
}

public enum LongviewStopReason: String, Codable, Equatable, Sendable {
  case frameLimitReached = "frame-limit-reached"
  case endReached = "end-reached"
  case singleFrame = "single-frame"
}

public struct LongviewCaptureRequest: Sendable {
  public let taskID: UUID
  public let target: TargetLease
  public let outputURL: URL
  public let maximumFrames: Int
  public let focusPolicy: LongviewFocusPolicy
  public let normalizedRegion: String?

  public init(
    taskID: UUID,
    target: TargetLease,
    outputURL: URL,
    maximumFrames: Int,
    focusPolicy: LongviewFocusPolicy,
    normalizedRegion: String? = nil
  ) {
    self.taskID = taskID
    self.target = target
    self.outputURL = outputURL
    self.maximumFrames = maximumFrames
    self.focusPolicy = focusPolicy
    self.normalizedRegion = normalizedRegion
  }
}

public struct LongviewCaptureOutcome: Sendable {
  public let artifact: ContextArtifact
  public let receipt: MutationReceipt
  public let capturedFrameCount: Int
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let effectivePixelsPerSecond: Int
  public let stopReason: LongviewStopReason
  public let detectedOverlaps: [Int]

  public init(
    artifact: ContextArtifact,
    receipt: MutationReceipt,
    capturedFrameCount: Int,
    pixelWidth: Int,
    pixelHeight: Int,
    effectivePixelsPerSecond: Int,
    stopReason: LongviewStopReason,
    detectedOverlaps: [Int]
  ) {
    self.artifact = artifact
    self.receipt = receipt
    self.capturedFrameCount = capturedFrameCount
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.effectivePixelsPerSecond = effectivePixelsPerSecond
    self.stopReason = stopReason
    self.detectedOverlaps = detectedOverlaps
  }
}

public enum LongviewAdapterError: Error, Equatable, Sendable {
  case invalidConfiguration(String)
  case invalidRequest(String)
  case processFailed(status: Int32, code: String?, message: String)
  case protocolViolation(String)
  case targetChanged
  case restorationUnverified
  case artifactMissing
}

public struct LongviewAdapter: Sendable {
  private let executableURL: URL
  private let runner: any ProcessRunning
  private let artifactTTL: TimeInterval

  public init(
    executableURL: URL,
    runner: any ProcessRunning = FoundationProcessRunner(),
    artifactTTL: TimeInterval = 300
  ) throws {
    guard executableURL.isFileURL, executableURL.path.hasPrefix("/") else {
      throw LongviewAdapterError.invalidConfiguration("executable path must be absolute")
    }
    self.executableURL = executableURL
    self.runner = runner
    self.artifactTTL = min(max(artifactTTL, 30), 3_600)
  }

  public func capture(
    _ request: LongviewCaptureRequest,
    now: Date = Date()
  ) async throws -> LongviewCaptureOutcome {
    try request.target.validate(now: now)
    guard request.outputURL.isFileURL, request.outputURL.path.hasPrefix("/") else {
      throw LongviewAdapterError.invalidRequest("output path must be absolute")
    }
    guard (1...100).contains(request.maximumFrames) else {
      throw LongviewAdapterError.invalidRequest("maximumFrames must be 1...100")
    }

    var arguments = [
      "--events",
      "longshot",
      "--output", request.outputURL.path,
      "--window-id", String(request.target.window.windowID),
      "--bundle-id", request.target.window.bundleIdentifier,
      "--max-frames", String(request.maximumFrames),
      "--focus-policy", request.focusPolicy.rawValue,
    ]
    if let region = request.normalizedRegion {
      arguments.append(contentsOf: ["--region", region])
    }

    let output = try await runner.run(
      executable: executableURL,
      arguments: arguments,
      environment: Self.sanitizedEnvironment
    )
    let terminalData = output.status == 0 ? output.standardOutput : output.standardError
    let terminalLines = [UInt8](terminalData).split(separator: 0x0A)
    guard let terminalBytes = terminalLines.last else {
      throw LongviewAdapterError.protocolViolation("missing terminal envelope")
    }
    let terminalLine = Data(terminalBytes)
    if output.status != 0 {
      let failure = try? JSONDecoder().decode(LongviewErrorEnvelope.self, from: terminalLine)
      throw LongviewAdapterError.processFailed(
        status: output.status,
        code: failure?.error.code,
        message: failure?.error.message ?? "Longview failed without a valid error envelope"
      )
    }

    let envelope: LongviewSuccessEnvelope
    do {
      envelope = try JSONDecoder().decode(LongviewSuccessEnvelope.self, from: terminalLine)
    } catch {
      throw LongviewAdapterError.protocolViolation("invalid schema-v2 result envelope")
    }
    guard envelope.schemaVersion == 2,
      envelope.ok,
      envelope.type == "result",
      envelope.command == "longshot"
    else {
      throw LongviewAdapterError.protocolViolation("unexpected Longview protocol identity")
    }
    guard envelope.result.target.processIdentifier == request.target.window.processIdentifier,
      envelope.result.target.windowNumber == request.target.window.windowID
    else {
      throw LongviewAdapterError.targetChanged
    }
    guard envelope.result.outputPath == request.outputURL.path,
      FileManager.default.fileExists(atPath: request.outputURL.path)
    else {
      throw LongviewAdapterError.artifactMissing
    }

    let recovery = RecoveryReceipt(
      viewport: envelope.result.viewportRestorationAttempted
        ? (envelope.result.viewportRestorationSucceeded
          ? .restored
          : .failed(reason: "Longview did not verify viewport restoration"))
        : .untouched,
      focus: envelope.result.targetWasActivated
        ? (envelope.result.focusRestorationSucceeded
          ? .restored
          : .failed(reason: "Longview did not verify focus restoration"))
        : .untouched,
      pointer: envelope.result.pointerWasMoved
        ? (envelope.result.pointerRestorationSucceeded
          ? .restored
          : .failed(reason: "Longview did not verify pointer restoration"))
        : .untouched,
      environment: envelope.result.environmentRestorationSucceeded
        ? .restored
        : .failed(reason: "Longview did not verify environment restoration"),
      cleanupVerifiedAt: Date()
    )
    guard recovery.isClean else {
      throw LongviewAdapterError.restorationUnverified
    }

    let data = try Data(contentsOf: request.outputURL, options: [.mappedIfSafe])
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let artifact = ContextArtifact(
      taskID: request.taskID,
      targetLeaseID: request.target.id,
      kind: .image,
      provider: .longview,
      providerVersion: "schema-v2",
      capturedAt: now,
      coherenceGroup: UUID(),
      scope: request.maximumFrames == 1 ? .window : .boundedHistory,
      mediaType: "image/png",
      privateURI: request.outputURL,
      byteCount: data.count,
      contentDigest: digest,
      sourceTrust: .hostObserved,
      sensitivity: .userContent,
      confidence: 1,
      complete: envelope.result.stopReason != .frameLimitReached,
      retention: ArtifactRetention(
        expiresAt: now.addingTimeInterval(artifactTTL),
        deleteAfterTask: true,
        memoryEligible: false
      )
    )
    try artifact.validate(now: now)

    let receipt = MutationReceipt(
      taskID: request.taskID,
      targetLeaseID: request.target.id,
      action: .read,
      executor: "LongviewAdapter",
      route: envelope.result.scrollRoute,
      beforeEvidenceArtifactIDs: [],
      postcondition: .verified(evidenceArtifactIDs: [artifact.id]),
      inverseOperationReference: nil,
      recovery: recovery,
      completedAt: Date()
    )
    return LongviewCaptureOutcome(
      artifact: artifact,
      receipt: receipt,
      capturedFrameCount: envelope.result.capturedFrameCount,
      pixelWidth: envelope.result.pixelWidth,
      pixelHeight: envelope.result.pixelHeight,
      effectivePixelsPerSecond: envelope.result.effectivePixelsPerSecond,
      stopReason: envelope.result.stopReason,
      detectedOverlaps: envelope.result.detectedOverlaps
    )
  }

  private static let sanitizedEnvironment: [String: String] = {
    var result: [String: String] = [:]
    for key in ["PATH", "TMPDIR", "LANG", "LC_ALL"] {
      if let value = ProcessInfo.processInfo.environment[key] {
        result[key] = value
      }
    }
    return result
  }()
}

private struct LongviewSuccessEnvelope: Decodable {
  let schemaVersion: Int
  let type: String
  let ok: Bool
  let command: String
  let result: Result

  struct Result: Decodable {
    let target: Target
    let outputPath: String
    let pixelWidth: Int
    let pixelHeight: Int
    let capturedFrameCount: Int
    let detectedOverlaps: [Int]
    let scrollRoute: String
    let stopReason: LongviewStopReason
    let targetWasActivated: Bool
    let pointerWasMoved: Bool
    let viewportRestorationAttempted: Bool
    let viewportRestorationSucceeded: Bool
    let environmentRestorationSucceeded: Bool
    let focusRestorationSucceeded: Bool
    let pointerRestorationSucceeded: Bool
    let effectivePixelsPerSecond: Int
  }

  struct Target: Decodable {
    let processIdentifier: Int32
    let windowNumber: UInt32?
  }
}

private struct LongviewErrorEnvelope: Decodable {
  let error: Body

  struct Body: Decodable {
    let code: String
    let message: String
  }
}
