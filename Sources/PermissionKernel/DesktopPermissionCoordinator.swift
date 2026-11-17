import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum DesktopPermission: String, CaseIterable, Codable, Sendable {
  case accessibility
  case screenRecording

  public var settingsRoute: SystemSettingsRoute {
    switch self {
    case .accessibility:
      SystemSettingsRoute(
        paneIdentifier: "com.apple.settings.PrivacySecurity.extension",
        anchor: "Privacy_Accessibility"
      )
    case .screenRecording:
      SystemSettingsRoute(
        paneIdentifier: "com.apple.settings.PrivacySecurity.extension",
        anchor: "Privacy_ScreenCapture"
      )
    }
  }
}

public enum DesktopPermissionStatus: String, Codable, Sendable {
  case authorized
  case deniedOrNotRequested
}

/// Immutable permission truth read from Apple's public preflight APIs. UI may
/// explain this state, but it never persists or invents a separate success bit.
public struct DesktopPermissionReadiness: Equatable, Codable, Sendable {
  public let accessibility: DesktopPermissionStatus
  public let screenRecording: DesktopPermissionStatus

  public init(
    accessibility: DesktopPermissionStatus,
    screenRecording: DesktopPermissionStatus
  ) {
    self.accessibility = accessibility
    self.screenRecording = screenRecording
  }

  public func status(for permission: DesktopPermission) -> DesktopPermissionStatus {
    switch permission {
    case .accessibility: accessibility
    case .screenRecording: screenRecording
    }
  }

  public var isReady: Bool {
    accessibility == .authorized && screenRecording == .authorized
  }

  public var remainingCount: Int {
    [accessibility, screenRecording].count { $0 != .authorized }
  }
}

/// A typed System Settings destination. Keeping pane identifiers here prevents
/// UI call sites from scattering fragile string literals across the product.
public struct SystemSettingsRoute: Equatable, Codable, Sendable {
  public let paneIdentifier: String
  public let anchor: String

  public init(paneIdentifier: String, anchor: String) {
    self.paneIdentifier = paneIdentifier
    self.anchor = anchor
  }

  public var url: URL? {
    URL(string: "x-apple.systempreferences:\(paneIdentifier)?\(anchor)")
  }
}

public enum DesktopPermissionSettingsError: Error, Equatable, Sendable {
  case invalidRoute(DesktopPermission)
  case openFailed(DesktopPermission)
}

/// The single owner of permission-related System Settings navigation.
@MainActor
public struct DesktopPermissionSettingsRouter {
  public init() {}

  public func open(_ permission: DesktopPermission) throws {
    guard let url = permission.settingsRoute.url else {
      throw DesktopPermissionSettingsError.invalidRoute(permission)
    }
    guard NSWorkspace.shared.open(url) else {
      throw DesktopPermissionSettingsError.openFailed(permission)
    }
  }
}

public struct DesktopPermissionCoordinator: Sendable {
  public init() {}

  public func readiness() -> DesktopPermissionReadiness {
    DesktopPermissionReadiness(
      accessibility: status(for: .accessibility),
      screenRecording: status(for: .screenRecording)
    )
  }

  public func status(for permission: DesktopPermission) -> DesktopPermissionStatus {
    switch permission {
    case .accessibility:
      AXIsProcessTrusted() ? .authorized : .deniedOrNotRequested
    case .screenRecording:
      CGPreflightScreenCaptureAccess() ? .authorized : .deniedOrNotRequested
    }
  }

  @discardableResult
  public func request(_ permission: DesktopPermission) -> DesktopPermissionStatus {
    switch permission {
    case .accessibility:
      // The SDK exposes this key as mutable global state, which is not concurrency-safe
      // under Swift 6. Its documented Core Foundation string value is stable.
      let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
      return AXIsProcessTrustedWithOptions(options) ? .authorized : .deniedOrNotRequested
    case .screenRecording:
      return CGRequestScreenCaptureAccess() ? .authorized : .deniedOrNotRequested
    }
  }
}
