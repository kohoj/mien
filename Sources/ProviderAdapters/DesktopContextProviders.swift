import AppKit
import ApplicationServices
import ArtifactStore
import ContextKernel
import Foundation
import MienContracts

public enum DesktopContextProviderError: Error, Equatable, Sendable {
  case unavailable
  case targetChanged
  case protectedContent
  case emptyContent
}

public struct SelectionContextProvider: ContextProvider {
  public let kind: ContextProviderKind = .selection

  private let selectedText: String?
  private let store: PrivateArtifactStore

  public init(snapshot: InvocationSnapshot, store: PrivateArtifactStore) {
    selectedText = snapshot.selectedText
    self.store = store
  }

  public func probe(target: TargetLease) async -> ProviderCapability {
    let available = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    return ProviderCapability(
      available: available,
      maximumScope: .selection,
      estimatedLatencyMilliseconds: 1,
      reason: available ? "selected text is frozen in the invocation snapshot" : "no selected text"
    )
  }

  public func capture(_ request: ContextCaptureRequest) async throws -> ContextCaptureOutcome {
    guard let text = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    else {
      throw DesktopContextProviderError.emptyContent
    }
    let bounded = String(text.prefix(request.budget.maximumTextCharacters))
    let artifact = try await store.store(
      Data(bounded.utf8),
      descriptor: ArtifactDescriptor(
        taskID: request.taskID,
        targetLeaseID: request.target.id,
        kind: .text,
        provider: .selection,
        providerVersion: "invocation-v1",
        coherenceGroup: request.coherenceGroup,
        scope: .selection,
        mediaType: "text/plain",
        sourceTrust: .untrustedContent,
        sensitivity: .userContent,
        confidence: 1,
        complete: bounded.count == text.count,
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
    return ContextCaptureOutcome(artifacts: [artifact])
  }
}

public struct AccessibilityContextProvider: ContextProvider {
  public let kind: ContextProviderKind = .accessibility

  private let store: PrivateArtifactStore
  private let maximumNodes: Int

  public init(store: PrivateArtifactStore, maximumNodes: Int = 160) {
    self.store = store
    self.maximumNodes = min(max(maximumNodes, 8), 500)
  }

  public func probe(target: TargetLease) async -> ProviderCapability {
    let trusted = AXIsProcessTrusted()
    let semanticTarget = target.semanticTarget
    let conversationCapable = semanticTarget?.ancestorRoles.contains("AXScrollArea") == true
    return ProviderCapability(
      available: trusted && semanticTarget?.frame != nil
        && semanticTarget?.protectedContent != true,
      maximumScope: conversationCapable ? .conversation : .semanticRegion,
      estimatedLatencyMilliseconds: 45,
      reason: trusted ? "semantic target is readable" : "Accessibility permission unavailable"
    )
  }

  public func capture(_ request: ContextCaptureRequest) async throws -> ContextCaptureOutcome {
    try WindowLeaseValidator().validate(request.target.window)
    let extraction = try Self.extract(
      target: request.target,
      requestedScope: request.requestedScope,
      maximumNodes: maximumNodes,
      maximumCharacters: request.budget.maximumTextCharacters
    )
    let payload = AccessibilityPayload(
      bundleIdentifier: request.target.window.bundleIdentifier,
      windowID: request.target.window.windowID,
      resolvedScope: extraction.scope,
      truncated: extraction.truncated,
      text: extraction.text
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(payload)
    guard data.count <= request.budget.maximumBytes else {
      throw DesktopContextProviderError.emptyContent
    }
    let artifact = try await store.store(
      data,
      descriptor: ArtifactDescriptor(
        taskID: request.taskID,
        targetLeaseID: request.target.id,
        kind: .accessibilityTree,
        provider: .accessibility,
        providerVersion: "macos-ax-v1",
        coherenceGroup: request.coherenceGroup,
        scope: extraction.scope,
        mediaType: "application/json",
        sourceTrust: .untrustedContent,
        sensitivity: .userContent,
        confidence: 0.98,
        complete: !extraction.truncated,
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
    return ContextCaptureOutcome(artifacts: [artifact])
  }

  private static func extract(
    target: TargetLease,
    requestedScope: ContextScope,
    maximumNodes: Int,
    maximumCharacters: Int
  ) throws -> Extraction {
    guard AXIsProcessTrusted(),
      let fingerprint = target.semanticTarget,
      let frame = fingerprint.frame
    else {
      throw DesktopContextProviderError.unavailable
    }
    guard !fingerprint.protectedContent else {
      throw DesktopContextProviderError.protectedContent
    }

    let application = AXUIElementCreateApplication(target.window.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.18)
    var hit: AXUIElement?
    let centerX = Float(frame.origin.x + frame.size.width / 2)
    let centerY = Float(frame.origin.y + frame.size.height / 2)
    guard AXUIElementCopyElementAtPosition(application, centerX, centerY, &hit) == .success,
      let hit
    else {
      throw DesktopContextProviderError.unavailable
    }
    try verify(hit, matches: fingerprint)

    let root: AXUIElement
    let scope: ContextScope
    if requestedScope.requestsConversationSemantics,
      let conversationRoot = ancestor(
        of: hit,
        matchingRoles: ["AXScrollArea", "AXList", "AXTable"],
        maximumDepth: 10
      )
    {
      root = conversationRoot
      scope = .conversation
    } else {
      root = hit
      scope = fingerprint.frame == nil ? .pointedElement : .semanticRegion
    }

    var queue: [AXUIElement] = [root]
    var nodeIndex = 0
    var pieces: [String] = []
    var characterCount = 0
    var truncated = false

    while nodeIndex < queue.count, nodeIndex < maximumNodes {
      let element = queue[nodeIndex]
      nodeIndex += 1
      if isProtected(element) { continue }

      for text in textualValues(element) where !text.isEmpty {
        if characterCount + text.count > maximumCharacters {
          let remaining = max(0, maximumCharacters - characterCount)
          if remaining > 0 { pieces.append(String(text.prefix(remaining))) }
          truncated = true
          break
        }
        pieces.append(text)
        characterCount += text.count
      }
      if truncated { break }
      queue.append(contentsOf: children(of: element))
    }
    if nodeIndex < queue.count { truncated = true }

    let text = deduplicated(pieces).joined(separator: "\n")
    guard !text.isEmpty else { throw DesktopContextProviderError.emptyContent }
    return Extraction(text: text, scope: scope, truncated: truncated)
  }

  private static func verify(
    _ element: AXUIElement,
    matches fingerprint: AXElementFingerprint
  ) throws {
    guard stringAttribute(element, kAXRoleAttribute) == fingerprint.role else {
      throw DesktopContextProviderError.targetChanged
    }
    if let expected = fingerprint.identifier,
      stringAttribute(element, kAXIdentifierAttribute) != expected
    {
      throw DesktopContextProviderError.targetChanged
    }
    if let expected = fingerprint.frame {
      guard let observed = frameAttribute(element) else {
        throw DesktopContextProviderError.targetChanged
      }
      let tolerance = 12.0
      guard abs(expected.origin.x - observed.origin.x) <= tolerance,
        abs(expected.origin.y - observed.origin.y) <= tolerance,
        abs(expected.size.width - observed.size.width) <= tolerance,
        abs(expected.size.height - observed.size.height) <= tolerance
      else {
        throw DesktopContextProviderError.targetChanged
      }
    }
    guard !isProtected(element) else {
      throw DesktopContextProviderError.protectedContent
    }
  }

  private static func ancestor(
    of element: AXUIElement,
    matchingRoles roles: Set<String>,
    maximumDepth: Int
  ) -> AXUIElement? {
    var current = elementAttribute(element, kAXParentAttribute)
    var depth = 0
    while let candidate = current, depth < maximumDepth {
      if let role = stringAttribute(candidate, kAXRoleAttribute), roles.contains(role) {
        return candidate
      }
      current = elementAttribute(candidate, kAXParentAttribute)
      depth += 1
    }
    return nil
  }

  private static func textualValues(_ element: AXUIElement) -> [String] {
    let attributes = [
      kAXSelectedTextAttribute,
      kAXValueAttribute,
      kAXDescriptionAttribute,
      kAXTitleAttribute,
      kAXHelpAttribute,
    ]
    return attributes.compactMap { stringAttribute(element, $0) }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
  }

  private static func deduplicated(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { seen.insert($0).inserted }
  }

  private static func isProtected(_ element: AXUIElement) -> Bool {
    let role = stringAttribute(element, kAXRoleAttribute)
    let subrole = stringAttribute(element, kAXSubroleAttribute)
    return role == "AXSecureTextField"
      || subrole == "AXSecureTextField"
      || boolAttribute(element, "AXContainsProtectedContent") == true
  }

  private static func copiedAttribute(
    _ element: AXUIElement,
    _ attribute: String
  ) -> CFTypeRef? {
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

  private static func stringAttribute(
    _ element: AXUIElement,
    _ attribute: String
  ) -> String? {
    guard let value = copiedAttribute(element, attribute) else { return nil }
    if let text = value as? String { return text }
    if let attributed = value as? NSAttributedString { return attributed.string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
  }

  private static func boolAttribute(
    _ element: AXUIElement,
    _ attribute: String
  ) -> Bool? {
    (copiedAttribute(element, attribute) as? NSNumber)?.boolValue
  }

  private static func elementAttribute(
    _ element: AXUIElement,
    _ attribute: String
  ) -> AXUIElement? {
    guard let value = copiedAttribute(element, attribute),
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return (value as! AXUIElement)
  }

  private static func children(of element: AXUIElement) -> [AXUIElement] {
    guard let value = copiedAttribute(element, kAXChildrenAttribute) else { return [] }
    if let children = value as? [AXUIElement] { return children }
    return []
  }

  private static func frameAttribute(_ element: AXUIElement) -> ScreenRect? {
    guard let positionValue = copiedAttribute(element, kAXPositionAttribute),
      let sizeValue = copiedAttribute(element, kAXSizeAttribute),
      CFGetTypeID(positionValue) == AXValueGetTypeID(),
      CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else {
      return nil
    }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
      AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    else {
      return nil
    }
    return ScreenRect(x: point.x, y: point.y, width: size.width, height: size.height)
  }
}

private struct AccessibilityPayload: Codable {
  let bundleIdentifier: String
  let windowID: UInt32
  let resolvedScope: ContextScope
  let truncated: Bool
  let text: String
}

private struct Extraction {
  let text: String
  let scope: ContextScope
  let truncated: Bool
}
