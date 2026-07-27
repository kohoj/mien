import Foundation

public struct WindowLease: Codable, Equatable, Hashable, Sendable, ContractValidating {
  public let processIdentifier: Int32
  public let windowID: UInt32
  public let bundleIdentifier: String
  public let frame: ScreenRect
  public let capturedAt: Date
  public let expiresAt: Date
  public let userInputEpoch: UInt64

  public init(
    processIdentifier: Int32,
    windowID: UInt32,
    bundleIdentifier: String,
    frame: ScreenRect,
    capturedAt: Date,
    expiresAt: Date,
    userInputEpoch: UInt64
  ) {
    self.processIdentifier = processIdentifier
    self.windowID = windowID
    self.bundleIdentifier = bundleIdentifier
    self.frame = frame
    self.capturedAt = capturedAt
    self.expiresAt = expiresAt
    self.userInputEpoch = userInputEpoch
  }

  public func validate(now: Date) throws {
    guard processIdentifier > 0 else {
      throw ContractValidationError.invalid("window.processIdentifier")
    }
    guard windowID != 0 else {
      throw ContractValidationError.invalid("window.windowID")
    }
    guard !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ContractValidationError.empty("window.bundleIdentifier")
    }
    guard frame.isValid else {
      throw ContractValidationError.invalid("window.frame")
    }
    guard expiresAt > capturedAt else {
      throw ContractValidationError.invalid("window.expiresAt")
    }
    guard now < expiresAt else {
      throw ContractValidationError.expired("windowLease")
    }
  }
}

public struct AXElementFingerprint: Codable, Equatable, Hashable, Sendable {
  public let role: String
  public let subrole: String?
  public let identifier: String?
  public let label: String?
  public let frame: ScreenRect?
  public let ancestorRoles: [String]
  public let protectedContent: Bool

  public init(
    role: String,
    subrole: String? = nil,
    identifier: String? = nil,
    label: String? = nil,
    frame: ScreenRect? = nil,
    ancestorRoles: [String] = [],
    protectedContent: Bool = false
  ) {
    self.role = role
    self.subrole = subrole
    self.identifier = identifier
    self.label = label
    self.frame = frame
    self.ancestorRoles = ancestorRoles
    self.protectedContent = protectedContent
  }
}

public struct EnvironmentSnapshot: Codable, Equatable, Hashable, Sendable {
  public let frontmostProcessIdentifier: Int32
  public let pointer: ScreenPoint
  public let displayID: UInt32
  public let userInputEpoch: UInt64

  public init(
    frontmostProcessIdentifier: Int32,
    pointer: ScreenPoint,
    displayID: UInt32,
    userInputEpoch: UInt64
  ) {
    self.frontmostProcessIdentifier = frontmostProcessIdentifier
    self.pointer = pointer
    self.displayID = displayID
    self.userInputEpoch = userInputEpoch
  }
}

public struct InvocationSnapshot: Codable, Equatable, Hashable, Sendable, Identifiable {
  public let id: UUID
  public let invokedAt: Date
  public let window: WindowLease
  public let pointedElement: AXElementFingerprint?
  public let focusedElement: AXElementFingerprint?
  public let selectedText: String?
  public let environment: EnvironmentSnapshot

  public init(
    id: UUID = UUID(),
    invokedAt: Date,
    window: WindowLease,
    pointedElement: AXElementFingerprint?,
    focusedElement: AXElementFingerprint?,
    selectedText: String?,
    environment: EnvironmentSnapshot
  ) {
    self.id = id
    self.invokedAt = invokedAt
    self.window = window
    self.pointedElement = pointedElement
    self.focusedElement = focusedElement
    self.selectedText = selectedText
    self.environment = environment
  }
}

public struct TargetLease: Codable, Equatable, Hashable, Sendable, Identifiable, ContractValidating
{
  public let id: UUID
  public let invocationSnapshotID: UUID
  public let window: WindowLease
  public let semanticTarget: AXElementFingerprint?
  public let issuedAt: Date
  public let expiresAt: Date

  public init(
    id: UUID = UUID(),
    invocationSnapshotID: UUID,
    window: WindowLease,
    semanticTarget: AXElementFingerprint?,
    issuedAt: Date,
    expiresAt: Date
  ) {
    self.id = id
    self.invocationSnapshotID = invocationSnapshotID
    self.window = window
    self.semanticTarget = semanticTarget
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
  }

  public func validate(now: Date) throws {
    try window.validate(now: now)
    guard expiresAt > issuedAt, expiresAt <= window.expiresAt else {
      throw ContractValidationError.invalid("targetLease.expiresAt")
    }
    guard now < expiresAt else {
      throw ContractValidationError.expired("targetLease")
    }
    if semanticTarget?.protectedContent == true {
      throw ContractValidationError.unauthorized("protected semantic target")
    }
  }
}
