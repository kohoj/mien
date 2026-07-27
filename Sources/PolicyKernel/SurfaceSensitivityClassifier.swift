import Foundation
import MienContracts

/// A deterministic preflight classifier used before any content bytes are read.
/// It intentionally favors false positives over transmitting authentication,
/// financial, or health surfaces as ordinary user content.
public struct SurfaceSensitivityClassifier: Sendable {
  public init() {}

  public func classify(
    bundleIdentifier: String,
    semanticTarget: AXElementFingerprint?
  ) -> Sensitivity {
    if semanticTarget?.protectedContent == true
      || semanticTarget?.role.localizedCaseInsensitiveContains("secure") == true
    {
      return .secret
    }
    let identifier = bundleIdentifier.lowercased()
    if Self.sensitiveIdentifierTokens.contains(where: identifier.contains) {
      return .sensitive
    }
    return .userContent
  }

  private static let sensitiveIdentifierTokens = [
    "authenticator",
    "bank",
    "finance",
    "health",
    "hospital",
    "medical",
    "password",
    "wallet",
  ]
}
