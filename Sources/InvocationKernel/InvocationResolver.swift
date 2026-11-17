import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MienContracts

public enum InvocationResolutionError: Error, Equatable, Sendable {
  case invalidPointer
  case noWindowAtPointer
  case missingBundleIdentifier
  case noDisplayAtPointer
  case targetChanged
}

public struct WindowSnapshot: Equatable, Sendable {
  public let processIdentifier: Int32
  public let windowID: UInt32
  public let bundleIdentifier: String
  public let frame: ScreenRect

  public init(
    processIdentifier: Int32,
    windowID: UInt32,
    bundleIdentifier: String,
    frame: ScreenRect
  ) {
    self.processIdentifier = processIdentifier
    self.windowID = windowID
    self.bundleIdentifier = bundleIdentifier
    self.frame = frame
  }
}

public struct SemanticSnapshot: Equatable, Sendable {
  public let pointedElement: AXElementFingerprint?
  public let focusedElement: AXElementFingerprint?
  public let selectedText: String?

  public init(
    pointedElement: AXElementFingerprint?,
    focusedElement: AXElementFingerprint?,
    selectedText: String?
  ) {
    self.pointedElement = pointedElement
    self.focusedElement = focusedElement
    self.selectedText = selectedText
  }
}

public protocol WindowSnapshotProviding: Sendable {
  func window(at point: ScreenPoint, excluding processIdentifier: Int32) throws -> WindowSnapshot
  /// Frontmost ordinary window of `processIdentifier`, for invocations that do
  /// not originate from a pointer position — a menu bar click, for instance,
  /// happens above every application window and so has no window under it.
  func frontmostWindow(of processIdentifier: Int32) throws -> WindowSnapshot
  func displayID(at point: ScreenPoint) throws -> UInt32
}

public protocol SemanticSnapshotProviding: Sendable {
  func snapshot(at point: ScreenPoint, processIdentifier: Int32) -> SemanticSnapshot
}

public struct InvocationResolver: Sendable {
  private let windowProvider: any WindowSnapshotProviding
  private let semanticProvider: any SemanticSnapshotProviding
  private let ownProcessIdentifier: Int32
  private let leaseDuration: TimeInterval

  public init(
    windowProvider: any WindowSnapshotProviding = SystemWindowSnapshotProvider(),
    semanticProvider: any SemanticSnapshotProviding = SystemSemanticSnapshotProvider(),
    ownProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
    leaseDuration: TimeInterval = 45
  ) {
    self.windowProvider = windowProvider
    self.semanticProvider = semanticProvider
    self.ownProcessIdentifier = ownProcessIdentifier
    self.leaseDuration = min(max(leaseDuration, 1), 45)
  }

  public func resolveCurrent(userInputEpoch: UInt64, now: Date = Date()) throws
    -> InvocationSnapshot
  {
    guard let location = CGEvent(source: nil)?.location else {
      throw InvocationResolutionError.invalidPointer
    }
    let pointer = ScreenPoint(x: location.x, y: location.y)
    let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    return try resolve(
      pointer: pointer,
      frontmostProcessIdentifier: frontmostPID,
      userInputEpoch: userInputEpoch,
      now: now
    )
  }

  /// Renews authority for a follow-up against the exact window identity that
  /// opened the conversation. This is a mechanical identity check, not semantic
  /// target inference: a missing or replaced window fails closed.
  public func renew(
    _ snapshot: InvocationSnapshot,
    userInputEpoch: UInt64? = nil,
    now: Date = Date()
  ) throws
    -> InvocationSnapshot
  {
    let current = try windowProvider.frontmostWindow(of: snapshot.window.processIdentifier)
    guard current.processIdentifier == snapshot.window.processIdentifier,
      current.windowID == snapshot.window.windowID,
      current.bundleIdentifier == snapshot.window.bundleIdentifier
    else {
      throw InvocationResolutionError.targetChanged
    }
    let originalPoint = snapshot.environment.pointer
    let point =
      current.frame.contains(originalPoint)
      ? originalPoint
      : ScreenPoint(
        x: current.frame.origin.x + current.frame.size.width / 2,
        y: current.frame.origin.y + current.frame.size.height / 2
      )
    let semantics = semanticProvider.snapshot(
      at: point,
      processIdentifier: current.processIdentifier
    )
    let renewedInputEpoch = userInputEpoch ?? snapshot.environment.userInputEpoch
    let lease = WindowLease(
      processIdentifier: current.processIdentifier,
      windowID: current.windowID,
      bundleIdentifier: current.bundleIdentifier,
      frame: current.frame,
      capturedAt: now,
      expiresAt: now.addingTimeInterval(leaseDuration),
      userInputEpoch: renewedInputEpoch
    )
    let environment = EnvironmentSnapshot(
      frontmostProcessIdentifier: current.processIdentifier,
      pointer: point,
      displayID: try windowProvider.displayID(at: point),
      userInputEpoch: renewedInputEpoch
    )
    return InvocationSnapshot(
      invokedAt: now,
      window: lease,
      pointedElement: semantics.pointedElement,
      focusedElement: semantics.focusedElement,
      selectedText: semantics.selectedText,
      environment: environment
    )
  }

  /// Resolves against the frontmost application rather than the pointer, for
  /// invocations that do not carry a meaningful cursor position — clicking the
  /// menu bar item leaves the cursor above every window, where no target
  /// exists. The semantic target then comes from keyboard focus.
  public func resolveFrontmost(
    frontmostProcessIdentifier: Int32? = nil,
    userInputEpoch: UInt64,
    now: Date = Date()
  ) throws -> InvocationSnapshot {
    let targetPID =
      frontmostProcessIdentifier
      ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
    guard let targetPID, targetPID > 0, targetPID != ownProcessIdentifier else {
      throw InvocationResolutionError.noWindowAtPointer
    }
    let window = try windowProvider.frontmostWindow(of: targetPID)
    let center = ScreenPoint(
      x: window.frame.origin.x + window.frame.size.width / 2,
      y: window.frame.origin.y + window.frame.size.height / 2
    )
    let semantics = semanticProvider.snapshot(
      at: center,
      processIdentifier: window.processIdentifier
    )
    let lease = WindowLease(
      processIdentifier: window.processIdentifier,
      windowID: window.windowID,
      bundleIdentifier: window.bundleIdentifier,
      frame: window.frame,
      capturedAt: now,
      expiresAt: now.addingTimeInterval(leaseDuration),
      userInputEpoch: userInputEpoch
    )
    let environment = EnvironmentSnapshot(
      frontmostProcessIdentifier: targetPID,
      pointer: center,
      displayID: (try? windowProvider.displayID(at: center)) ?? 0,
      userInputEpoch: userInputEpoch
    )
    return InvocationSnapshot(
      invokedAt: now,
      window: lease,
      pointedElement: nil,
      focusedElement: semantics.focusedElement,
      selectedText: semantics.selectedText,
      environment: environment
    )
  }

  public func resolve(
    pointer: ScreenPoint,
    frontmostProcessIdentifier: Int32,
    userInputEpoch: UInt64,
    now: Date = Date()
  ) throws -> InvocationSnapshot {
    guard pointer.isFinite else { throw InvocationResolutionError.invalidPointer }

    // The target is the application the user is working in, not whatever the
    // cursor happens to rest above. Those differ constantly: the overlay opens
    // near the pointer, so the pointer often ends up over a window behind or
    // beside the one being read. Prefer the frontmost application's window and
    // fall back to the pointer only when it has none on screen.
    let window: WindowSnapshot
    if frontmostProcessIdentifier > 0,
      frontmostProcessIdentifier != ownProcessIdentifier,
      let frontWindow = try? windowProvider.frontmostWindow(of: frontmostProcessIdentifier)
    {
      window = frontWindow
    } else {
      window = try windowProvider.window(at: pointer, excluding: ownProcessIdentifier)
    }
    let displayID = try windowProvider.displayID(at: pointer)
    // Element lookup stays pointer-based, but only inside the chosen window: a
    // pointer outside it would resolve to nothing and leave `pointedElement`
    // nil, which the coordinator already handles by falling back to focus.
    let semanticPoint =
      window.frame.contains(pointer)
      ? pointer
      : ScreenPoint(
        x: window.frame.origin.x + window.frame.size.width / 2,
        y: window.frame.origin.y + window.frame.size.height / 2
      )
    let semantics = semanticProvider.snapshot(
      at: semanticPoint,
      processIdentifier: window.processIdentifier
    )
    let lease = WindowLease(
      processIdentifier: window.processIdentifier,
      windowID: window.windowID,
      bundleIdentifier: window.bundleIdentifier,
      frame: window.frame,
      capturedAt: now,
      expiresAt: now.addingTimeInterval(leaseDuration),
      userInputEpoch: userInputEpoch
    )
    let environment = EnvironmentSnapshot(
      frontmostProcessIdentifier: frontmostProcessIdentifier,
      pointer: pointer,
      displayID: displayID,
      userInputEpoch: userInputEpoch
    )
    return InvocationSnapshot(
      invokedAt: now,
      window: lease,
      pointedElement: semantics.pointedElement,
      focusedElement: semantics.focusedElement,
      selectedText: semantics.selectedText,
      environment: environment
    )
  }
}

public struct SystemWindowSnapshotProvider: WindowSnapshotProviding {
  public init() {}

  public func window(
    at point: ScreenPoint,
    excluding processIdentifier: Int32
  ) throws -> WindowSnapshot {
    guard point.isFinite else { throw InvocationResolutionError.invalidPointer }
    let match = try Self.firstOrdinaryWindow { candidate in
      candidate.processIdentifier != processIdentifier && candidate.frame.contains(point)
    }
    return match
  }

  public func frontmostWindow(of processIdentifier: Int32) throws -> WindowSnapshot {
    guard processIdentifier > 0 else { throw InvocationResolutionError.noWindowAtPointer }
    // CGWindowListCopyWindowInfo returns front-to-back, so the first match is
    // the window the user was last looking at.
    return try Self.firstOrdinaryWindow { $0.processIdentifier == processIdentifier }
  }

  /// Walks on-screen windows in front-to-back order and returns the first
  /// ordinary (layer 0) window of a bundled application satisfying `predicate`.
  private static func firstOrdinaryWindow(
    where predicate: (WindowSnapshot) -> Bool
  ) throws -> WindowSnapshot {
    guard
      let raw = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[String: Any]]
    else {
      throw InvocationResolutionError.noWindowAtPointer
    }

    for info in raw {
      guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
        ownerPID > 0,
        let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
        windowID != 0,
        let frame = Self.frame(from: info[kCGWindowBounds as String])
      else {
        continue
      }

      guard let application = NSRunningApplication(processIdentifier: ownerPID),
        let bundleIdentifier = application.bundleIdentifier,
        !bundleIdentifier.isEmpty
      else {
        continue
      }
      let candidate = WindowSnapshot(
        processIdentifier: ownerPID,
        windowID: windowID,
        bundleIdentifier: bundleIdentifier,
        frame: frame
      )
      if predicate(candidate) { return candidate }
    }
    throw InvocationResolutionError.noWindowAtPointer
  }

  public func displayID(at point: ScreenPoint) throws -> UInt32 {
    var displayID = CGDirectDisplayID()
    var count: UInt32 = 0
    let error = CGGetDisplaysWithPoint(
      CGPoint(x: point.x, y: point.y),
      1,
      &displayID,
      &count
    )
    guard error == .success, count == 1 else {
      throw InvocationResolutionError.noDisplayAtPointer
    }
    return displayID
  }

  private static func frame(from value: Any?) -> ScreenRect? {
    guard let dictionary = value as? [String: Any] else { return nil }
    var rect = CGRect.zero
    guard CGRectMakeWithDictionaryRepresentation(dictionary as CFDictionary, &rect),
      rect.width > 0,
      rect.height > 0
    else {
      return nil
    }
    return ScreenRect(
      x: rect.origin.x,
      y: rect.origin.y,
      width: rect.width,
      height: rect.height
    )
  }
}

public struct SystemSemanticSnapshotProvider: SemanticSnapshotProviding {
  private let maximumAncestorDepth: Int

  public init(maximumAncestorDepth: Int = 8) {
    self.maximumAncestorDepth = max(0, maximumAncestorDepth)
  }

  public func snapshot(at point: ScreenPoint, processIdentifier: Int32) -> SemanticSnapshot {
    guard AXIsProcessTrusted(), processIdentifier > 0 else {
      return SemanticSnapshot(pointedElement: nil, focusedElement: nil, selectedText: nil)
    }

    let application = AXUIElementCreateApplication(processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.12)

    var pointed: AXUIElement?
    let pointedError = AXUIElementCopyElementAtPosition(
      application,
      Float(point.x),
      Float(point.y),
      &pointed
    )
    let pointedFingerprint =
      pointedError == .success
      ? pointed.map { fingerprint($0, includeAncestors: true) }
      : nil

    let focused = elementAttribute(application, kAXFocusedUIElementAttribute)
    let focusedFingerprint = focused.map { fingerprint($0, includeAncestors: false) }
    let selectedText: String?
    if let focused,
      focusedFingerprint?.protectedContent != true,
      Self.sameSemanticSurface(focusedFingerprint, pointedFingerprint)
    {
      selectedText = stringAttribute(focused, kAXSelectedTextAttribute)
    } else {
      selectedText = nil
    }

    return SemanticSnapshot(
      pointedElement: pointedFingerprint,
      focusedElement: focusedFingerprint,
      selectedText: selectedText?.isEmpty == false ? selectedText : nil
    )
  }

  private static func sameSemanticSurface(
    _ focused: AXElementFingerprint?,
    _ pointed: AXElementFingerprint?
  ) -> Bool {
    guard let focused, let pointed else { return false }
    if let focusedID = focused.identifier, let pointedID = pointed.identifier {
      return focusedID == pointedID
    }
    guard let focusedFrame = focused.frame, let pointedFrame = pointed.frame else { return false }
    let lhs = CGRect(
      x: focusedFrame.origin.x,
      y: focusedFrame.origin.y,
      width: focusedFrame.size.width,
      height: focusedFrame.size.height
    )
    let rhs = CGRect(
      x: pointedFrame.origin.x,
      y: pointedFrame.origin.y,
      width: pointedFrame.size.width,
      height: pointedFrame.size.height
    )
    return lhs.intersects(rhs)
  }

  private func fingerprint(
    _ element: AXUIElement,
    includeAncestors: Bool
  ) -> AXElementFingerprint {
    let role = stringAttribute(element, kAXRoleAttribute) ?? "AXUnknown"
    let subrole = stringAttribute(element, kAXSubroleAttribute)
    let protected =
      role == "AXSecureTextField"
      || subrole == "AXSecureTextField"
      || boolAttribute(element, "AXContainsProtectedContent") == true

    var ancestors: [String] = []
    if includeAncestors {
      var current = elementAttribute(element, kAXParentAttribute)
      while let ancestor = current, ancestors.count < maximumAncestorDepth {
        ancestors.append(stringAttribute(ancestor, kAXRoleAttribute) ?? "AXUnknown")
        current = elementAttribute(ancestor, kAXParentAttribute)
      }
    }

    return AXElementFingerprint(
      role: role,
      subrole: subrole,
      identifier: stringAttribute(element, kAXIdentifierAttribute),
      label: protected ? nil : stringAttribute(element, kAXTitleAttribute),
      frame: frameAttribute(element),
      ancestorRoles: ancestors,
      protectedContent: protected
    )
  }

  private func copiedAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &value
      ) == .success
    else {
      return nil
    }
    return value
  }

  private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = copiedAttribute(element, attribute),
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return (value as! AXUIElement)
  }

  private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    guard let value = copiedAttribute(element, attribute) else { return nil }
    if let string = value as? String { return string }
    if let attributed = value as? NSAttributedString { return attributed.string }
    return nil
  }

  private func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
    (copiedAttribute(element, attribute) as? NSNumber)?.boolValue
  }

  private func frameAttribute(_ element: AXUIElement) -> ScreenRect? {
    guard let position = axPoint(element, kAXPositionAttribute),
      let size = axSize(element, kAXSizeAttribute),
      size.width > 0,
      size.height > 0
    else {
      return nil
    }
    return ScreenRect(
      x: position.x,
      y: position.y,
      width: size.width,
      height: size.height
    )
  }

  private func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
    guard let value = copiedAttribute(element, attribute),
      CFGetTypeID(value) == AXValueGetTypeID()
    else {
      return nil
    }
    var point = CGPoint.zero
    guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
    return point
  }

  private func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
    guard let value = copiedAttribute(element, attribute),
      CFGetTypeID(value) == AXValueGetTypeID()
    else {
      return nil
    }
    var size = CGSize.zero
    guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
    return size
  }
}
