import ApplicationServices
import CoreGraphics
import Foundation

public enum DesktopPermission: String, Codable, Sendable {
  case accessibility
  case screenRecording
}

public enum DesktopPermissionStatus: String, Codable, Sendable {
  case authorized
  case deniedOrNotRequested
}

public struct DesktopPermissionCoordinator: Sendable {
  public init() {}

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
