import CoreGraphics
import Foundation
import MienContracts

public struct WindowLeaseValidator: Sendable {
  public init() {}

  public func validate(_ lease: WindowLease, now: Date = Date()) throws {
    try lease.validate(now: now)
    guard
      let windows = CGWindowListCopyWindowInfo(
        [.optionIncludingWindow, .excludeDesktopElements],
        CGWindowID(lease.windowID)
      ) as? [[CFString: Any]],
      let window = windows.first,
      (window[kCGWindowNumber] as? NSNumber)?.uint32Value == lease.windowID,
      (window[kCGWindowOwnerPID] as? NSNumber)?.int32Value == lease.processIdentifier,
      let bounds = window[kCGWindowBounds] as? [String: Any]
    else {
      throw DesktopContextProviderError.targetChanged
    }
    var observed = CGRect.zero
    guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &observed) else {
      throw DesktopContextProviderError.targetChanged
    }
    let expected = lease.frame
    let tolerance = 4.0
    guard abs(expected.origin.x - observed.origin.x) <= tolerance,
      abs(expected.origin.y - observed.origin.y) <= tolerance,
      abs(expected.size.width - observed.size.width) <= tolerance,
      abs(expected.size.height - observed.size.height) <= tolerance
    else {
      throw DesktopContextProviderError.targetChanged
    }
  }
}
