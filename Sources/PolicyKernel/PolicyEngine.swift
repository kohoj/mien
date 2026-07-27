import Foundation
import MienContracts

public enum PolicyOperation: String, Codable, Sendable {
  case inspectMetadata
  case readAccessibility
  case capturePixels
  case performOCR
  case transmit
  case remember
  case mutate
  case externalCommit
  case destructive
}

public enum PolicyDestination: String, Codable, Sendable {
  case hostOnly
  case localModel
  case codex
  case externalApplication
  case persistentMemory
}

public struct PolicySubject: Codable, Equatable, Sendable {
  public let bundleIdentifier: String
  public let windowID: UInt32
  public let scope: ContextScope
  public let protectedContent: Bool

  public init(
    bundleIdentifier: String,
    windowID: UInt32,
    scope: ContextScope,
    protectedContent: Bool
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.windowID = windowID
    self.scope = scope
    self.protectedContent = protectedContent
  }
}

public struct PolicyRequest: Codable, Equatable, Sendable {
  public let taskID: UUID
  public let subject: PolicySubject
  public let operation: PolicyOperation
  public let sensitivity: Sensitivity
  public let destination: PolicyDestination
  public let userInitiated: Bool
  public let approvalReference: String?

  public init(
    taskID: UUID,
    subject: PolicySubject,
    operation: PolicyOperation,
    sensitivity: Sensitivity,
    destination: PolicyDestination,
    userInitiated: Bool,
    approvalReference: String? = nil
  ) {
    self.taskID = taskID
    self.subject = subject
    self.operation = operation
    self.sensitivity = sensitivity
    self.destination = destination
    self.userInitiated = userInitiated
    self.approvalReference = approvalReference
  }
}

public enum PolicyDecision: Equatable, Sendable {
  case allow(reason: String)
  case requireApproval(reason: String)
  case deny(reason: String)
}

public struct PolicyConfiguration: Equatable, Sendable {
  public let deniedBundleIdentifiers: Set<String>
  public let locallyAllowedSensitiveBundleIdentifiers: Set<String>

  public init(
    deniedBundleIdentifiers: Set<String> = PolicyConfiguration.defaultDeniedBundles,
    locallyAllowedSensitiveBundleIdentifiers: Set<String> = []
  ) {
    self.deniedBundleIdentifiers = deniedBundleIdentifiers
    self.locallyAllowedSensitiveBundleIdentifiers = locallyAllowedSensitiveBundleIdentifiers
  }

  public static let defaultDeniedBundles: Set<String> = [
    "com.apple.keychainaccess",
    "com.1password.1password",
    "com.agilebits.onepassword7",
    "com.apple.Passwords",
  ]
}

public struct PolicyEngine: Sendable {
  private let configuration: PolicyConfiguration

  public init(configuration: PolicyConfiguration = PolicyConfiguration()) {
    self.configuration = configuration
  }

  public func evaluate(_ request: PolicyRequest) -> PolicyDecision {
    if configuration.deniedBundleIdentifiers.contains(request.subject.bundleIdentifier) {
      return .deny(reason: "application is excluded by deterministic policy")
    }
    if request.subject.protectedContent || request.sensitivity == .secret {
      return .deny(reason: "protected or secret content is fail-closed")
    }
    if !request.userInitiated, request.operation != .inspectMetadata {
      return .deny(reason: "desktop context requires a user-initiated task")
    }
    if request.sensitivity == .sensitive,
      request.destination != .hostOnly,
      request.destination != .localModel
    {
      return .deny(reason: "sensitive content cannot leave the host boundary")
    }
    if request.operation == .externalCommit || request.operation == .destructive {
      guard request.approvalReference?.isEmpty == false else {
        return .requireApproval(reason: "confirm the exact external consequence")
      }
    }
    if request.operation == .remember, request.destination == .persistentMemory {
      guard request.approvalReference?.isEmpty == false else {
        return .requireApproval(reason: "persistent memory requires provenance-aware approval")
      }
    }
    return .allow(reason: "request is within the explicit task and destination scope")
  }
}
