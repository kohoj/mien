import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MienContracts

public actor SystemAXDraftMutationDriver: DraftMutationDriving {
  private struct Binding {
    let application: AXUIElement
    let window: AXUIElement
    let field: AXUIElement
    let bundleIdentifier: String
    let processIdentifier: Int32
    let windowID: UInt32
    let fingerprint: AXElementFingerprint
    let expiresAt: Date
  }

  private let handleDuration: TimeInterval
  private let maximumTraversalElements: Int
  private var bindings: [UUID: Binding] = [:]

  public init(handleDuration: TimeInterval = 120, maximumTraversalElements: Int = 256) {
    self.handleDuration = min(max(handleDuration, 30), 300)
    self.maximumTraversalElements = min(max(maximumTraversalElements, 32), 1_024)
  }

  public func bind(
    window sourceWindow: WindowLease,
    element expected: AXElementFingerprint,
    now: Date,
    leaseDuration: TimeInterval
  ) async throws -> BoundDraftField {
    guard AXIsProcessTrusted() else {
      throw DraftMutationError.accessibilityPermissionMissing
    }
    guard !expected.protectedContent else { throw DraftMutationError.protectedField }
    guard isEditableRole(expected.role) else { throw DraftMutationError.fieldNotEditable }
    guard let running = NSRunningApplication(processIdentifier: sourceWindow.processIdentifier),
      !running.isTerminated,
      running.bundleIdentifier == sourceWindow.bundleIdentifier
    else {
      throw DraftMutationError.applicationUnavailable
    }
    guard
      let liveFrame = liveWindowFrame(
        windowID: sourceWindow.windowID,
        processIdentifier: sourceWindow.processIdentifier
      ), framesMatch(liveFrame, sourceWindow.frame, tolerance: 2)
    else {
      throw DraftMutationError.targetChanged
    }

    let application = AXUIElementCreateApplication(sourceWindow.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.25)
    guard
      let window = matchingWindow(
        in: application,
        windowID: sourceWindow.windowID,
        frame: liveFrame
      )
    else {
      throw DraftMutationError.targetChanged
    }
    guard
      let field = matchingEditableField(
        in: application,
        window: window,
        expected: expected
      )
    else {
      throw DraftMutationError.targetChanged
    }
    guard !isProtected(field) else { throw DraftMutationError.protectedField }
    guard isAttributeSettable(field, kAXValueAttribute) else {
      throw DraftMutationError.fieldNotEditable
    }
    let state = try readState(field)
    if state.selection == nil, !state.value.isEmpty {
      throw DraftMutationError.selectionUnavailable
    }

    let currentFingerprint = fingerprint(field)
    let duration = min(max(leaseDuration, 2), 30)
    let windowLease = WindowLease(
      processIdentifier: sourceWindow.processIdentifier,
      windowID: sourceWindow.windowID,
      bundleIdentifier: sourceWindow.bundleIdentifier,
      frame: liveFrame,
      capturedAt: now,
      expiresAt: now.addingTimeInterval(duration),
      userInputEpoch: sourceWindow.userInputEpoch
    )
    let target = TargetLease(
      invocationSnapshotID: UUID(),
      window: windowLease,
      semanticTarget: currentFingerprint,
      issuedAt: now,
      expiresAt: now.addingTimeInterval(duration)
    )
    try target.validate(now: now)

    let handle = UUID()
    bindings[handle] = Binding(
      application: application,
      window: window,
      field: field,
      bundleIdentifier: sourceWindow.bundleIdentifier,
      processIdentifier: sourceWindow.processIdentifier,
      windowID: sourceWindow.windowID,
      fingerprint: currentFingerprint,
      expiresAt: now.addingTimeInterval(handleDuration)
    )
    return BoundDraftField(handle: handle, target: target, state: state)
  }

  public func read(handle: UUID, target: TargetLease, now: Date) async throws -> DraftFieldState {
    let binding = try validatedBinding(handle: handle, target: target, now: now)
    return try readState(binding.field)
  }

  public func write(
    _ state: DraftFieldState,
    handle: UUID,
    target: TargetLease,
    now: Date
  ) async throws {
    let binding = try validatedBinding(handle: handle, target: target, now: now)
    let error = AXUIElementSetAttributeValue(
      binding.field,
      kAXValueAttribute as CFString,
      state.value as CFString
    )
    guard error == .success else { throw DraftMutationError.writeFailed(error.rawValue) }
    if let selection = state.selection,
      isAttributeSettable(binding.field, kAXSelectedTextRangeAttribute)
    {
      var range = CFRange(location: selection.location, length: selection.length)
      guard let value = AXValueCreate(.cfRange, &range) else {
        throw DraftMutationError.invalidSelection
      }
      let selectionError = AXUIElementSetAttributeValue(
        binding.field,
        kAXSelectedTextRangeAttribute as CFString,
        value
      )
      guard selectionError == .success else {
        throw DraftMutationError.writeFailed(selectionError.rawValue)
      }
    }
  }

  public func release(handle: UUID) async {
    bindings.removeValue(forKey: handle)
  }

  private func validatedBinding(
    handle: UUID,
    target: TargetLease,
    now: Date
  ) throws -> Binding {
    guard let binding = bindings[handle] else { throw DraftMutationError.targetChanged }
    guard now < binding.expiresAt else {
      bindings.removeValue(forKey: handle)
      throw DraftMutationError.targetExpired
    }
    do {
      try target.validate(now: now)
    } catch {
      throw DraftMutationError.targetExpired
    }
    guard target.window.processIdentifier == binding.processIdentifier,
      target.window.windowID == binding.windowID,
      target.window.bundleIdentifier == binding.bundleIdentifier,
      target.semanticTarget == binding.fingerprint,
      let running = NSRunningApplication(processIdentifier: binding.processIdentifier),
      !running.isTerminated,
      running.bundleIdentifier == binding.bundleIdentifier,
      let liveFrame = liveWindowFrame(
        windowID: binding.windowID,
        processIdentifier: binding.processIdentifier
      ),
      framesMatch(liveFrame, target.window.frame, tolerance: 2),
      matchingWindow(
        in: binding.application,
        windowID: binding.windowID,
        frame: liveFrame
      ).map({ CFEqual($0, binding.window) }) == true,
      fingerprint(binding.field) == binding.fingerprint,
      !isProtected(binding.field),
      isAttributeSettable(binding.field, kAXValueAttribute)
    else {
      throw DraftMutationError.targetChanged
    }
    if let focused = elementAttribute(binding.application, kAXFocusedUIElementAttribute),
      !CFEqual(focused, binding.field)
    {
      throw DraftMutationError.targetChanged
    }
    return binding
  }

  private func matchingWindow(
    in application: AXUIElement,
    windowID: UInt32,
    frame: ScreenRect
  ) -> AXUIElement? {
    let windows = elementArrayAttribute(application, kAXWindowsAttribute)
    if let exact = windows.first(where: {
      numericAttribute($0, "_AXWindowID")?.uint32Value == windowID
    }) {
      return exact
    }
    return windows.first { candidate in
      guard let candidateFrame = frameAttribute(candidate) else { return false }
      return framesMatch(candidateFrame, frame, tolerance: 2)
    }
  }

  private func matchingEditableField(
    in application: AXUIElement,
    window: AXUIElement,
    expected: AXElementFingerprint
  ) -> AXUIElement? {
    if let focused = elementAttribute(application, kAXFocusedUIElementAttribute),
      fingerprintMatches(focused, expected: expected),
      descends(focused, from: window)
    {
      return focused
    }
    if let frame = expected.frame {
      var element: AXUIElement?
      let x = Float(frame.origin.x + frame.size.width / 2)
      let y = Float(frame.origin.y + frame.size.height / 2)
      if AXUIElementCopyElementAtPosition(application, x, y, &element) == .success,
        let element,
        let editable = editableAncestor(from: element, expected: expected, within: window)
      {
        return editable
      }
    }

    var queue = [window]
    var index = 0
    while index < queue.count, index < maximumTraversalElements {
      let candidate = queue[index]
      index += 1
      if fingerprintMatches(candidate, expected: expected) { return candidate }
      queue.append(contentsOf: elementArrayAttribute(candidate, kAXChildrenAttribute))
      if queue.count > maximumTraversalElements {
        queue.removeSubrange(maximumTraversalElements..<queue.count)
      }
    }
    return nil
  }

  private func editableAncestor(
    from element: AXUIElement,
    expected: AXElementFingerprint,
    within window: AXUIElement
  ) -> AXUIElement? {
    var current: AXUIElement? = element
    var depth = 0
    while let candidate = current, depth < 8 {
      if fingerprintMatches(candidate, expected: expected), descends(candidate, from: window) {
        return candidate
      }
      if CFEqual(candidate, window) { return nil }
      current = elementAttribute(candidate, kAXParentAttribute)
      depth += 1
    }
    return nil
  }

  private func descends(_ element: AXUIElement, from window: AXUIElement) -> Bool {
    var current: AXUIElement? = element
    var depth = 0
    while let candidate = current, depth < 32 {
      if CFEqual(candidate, window) { return true }
      current = elementAttribute(candidate, kAXParentAttribute)
      depth += 1
    }
    return false
  }

  private func fingerprintMatches(
    _ element: AXUIElement,
    expected: AXElementFingerprint
  ) -> Bool {
    guard isEditableRole(expected.role), !expected.protectedContent else { return false }
    let candidate = fingerprint(element)
    guard candidate.role == expected.role, !candidate.protectedContent else { return false }
    if let identifier = expected.identifier {
      guard candidate.identifier == identifier else { return false }
    }
    if let frame = expected.frame {
      guard let candidateFrame = candidate.frame,
        framesMatch(candidateFrame, frame, tolerance: 2)
      else { return false }
    }
    return expected.identifier != nil || expected.frame != nil
  }

  private func fingerprint(_ element: AXUIElement) -> AXElementFingerprint {
    let role = stringAttribute(element, kAXRoleAttribute) ?? "AXUnknown"
    let subrole = stringAttribute(element, kAXSubroleAttribute)
    return AXElementFingerprint(
      role: role,
      subrole: subrole,
      identifier: stringAttribute(element, kAXIdentifierAttribute),
      label: nil,
      frame: frameAttribute(element),
      ancestorRoles: [],
      protectedContent: isProtected(element)
    )
  }

  private func readState(_ field: AXUIElement) throws -> DraftFieldState {
    guard let value = copiedAttribute(field, kAXValueAttribute) else {
      throw DraftMutationError.fieldNotEditable
    }
    let text: String
    if let string = value as? String {
      text = string
    } else if let attributed = value as? NSAttributedString {
      text = attributed.string
    } else {
      throw DraftMutationError.fieldNotEditable
    }
    let selection = rangeAttribute(field, kAXSelectedTextRangeAttribute)
    if let selection { try selection.validate(utf16Count: (text as NSString).length) }
    return DraftFieldState(value: text, selection: selection)
  }

  private func liveWindowFrame(windowID: UInt32, processIdentifier: Int32) -> ScreenRect? {
    guard
      let info = CGWindowListCopyWindowInfo(
        .optionIncludingWindow,
        CGWindowID(windowID)
      ) as? [[String: Any]],
      let window = info.first,
      (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
      let rawBounds = window[kCGWindowBounds as String] as? [String: Any]
    else {
      return nil
    }
    var rect = CGRect.zero
    guard CGRectMakeWithDictionaryRepresentation(rawBounds as CFDictionary, &rect),
      rect.width > 0, rect.height > 0
    else {
      return nil
    }
    return ScreenRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
  }

  private func framesMatch(_ lhs: ScreenRect, _ rhs: ScreenRect, tolerance: Double) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) <= tolerance
      && abs(lhs.origin.y - rhs.origin.y) <= tolerance
      && abs(lhs.size.width - rhs.size.width) <= tolerance
      && abs(lhs.size.height - rhs.size.height) <= tolerance
  }

  private func copiedAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = copiedAttribute(element, attribute),
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
  }

  private func elementArrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
    guard let values = copiedAttribute(element, attribute) as? [Any] else { return [] }
    return values.compactMap { value in
      let reference = value as CFTypeRef
      guard CFGetTypeID(reference) == AXUIElementGetTypeID() else { return nil }
      return (reference as! AXUIElement)
    }
  }

  private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    guard let value = copiedAttribute(element, attribute) else { return nil }
    if let string = value as? String { return string }
    if let attributed = value as? NSAttributedString { return attributed.string }
    return nil
  }

  private func numericAttribute(_ element: AXUIElement, _ attribute: String) -> NSNumber? {
    copiedAttribute(element, attribute) as? NSNumber
  }

  private func frameAttribute(_ element: AXUIElement) -> ScreenRect? {
    guard let point = pointAttribute(element, kAXPositionAttribute),
      let size = sizeAttribute(element, kAXSizeAttribute),
      size.width > 0, size.height > 0
    else { return nil }
    return ScreenRect(x: point.x, y: point.y, width: size.width, height: size.height)
  }

  private func pointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
    guard let value = copiedAttribute(element, attribute),
      CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
    return point
  }

  private func sizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
    guard let value = copiedAttribute(element, attribute),
      CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
    return size
  }

  private func rangeAttribute(_ element: AXUIElement, _ attribute: String) -> DraftSelection? {
    guard let value = copiedAttribute(element, attribute),
      CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
    return DraftSelection(location: range.location, length: range.length)
  }

  private func isAttributeSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
      && settable.boolValue
  }

  private func isProtected(_ element: AXUIElement) -> Bool {
    let role = stringAttribute(element, kAXRoleAttribute)
    let subrole = stringAttribute(element, kAXSubroleAttribute)
    return role == "AXSecureTextField"
      || subrole == "AXSecureTextField"
      || (copiedAttribute(element, "AXContainsProtectedContent") as? NSNumber)?.boolValue == true
  }

  private func isEditableRole(_ role: String) -> Bool {
    role == "AXTextField" || role == "AXTextArea"
  }
}
