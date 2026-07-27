import CryptoKit
import Foundation
import MienContracts

enum DraftTextTransaction {
  static let maximumDraftUTF8Bytes = 256 * 1_024

  static func applying(_ draft: String, to state: DraftFieldState) throws -> DraftFieldState {
    guard !draft.isEmpty else { throw DraftMutationError.emptyDraft }
    guard draft.lengthOfBytes(using: .utf8) <= maximumDraftUTF8Bytes else {
      throw DraftMutationError.draftTooLarge
    }

    let original = state.value as NSString
    let selection: DraftSelection
    let canVerifyCaret: Bool
    if let current = state.selection {
      try current.validate(utf16Count: original.length)
      selection = current
      canVerifyCaret = true
    } else if original.length == 0 {
      selection = DraftSelection(location: 0, length: 0)
      canVerifyCaret = false
    } else {
      // Never destroy an existing draft when the target cannot expose a caret.
      throw DraftMutationError.selectionUnavailable
    }

    let range = NSRange(location: selection.location, length: selection.length)
    let value = original.replacingCharacters(in: range, with: draft)
    let caret = selection.location + (draft as NSString).length
    return DraftFieldState(
      value: value,
      selection: canVerifyCaret ? DraftSelection(location: caret, length: 0) : nil
    )
  }

  static func digest(target: TargetLease, state: DraftFieldState) -> String {
    let selection = state.selection.map { "\($0.location):\($0.length)" } ?? "none"
    let components = [
      String(target.window.processIdentifier),
      String(target.window.windowID),
      target.window.bundleIdentifier,
      target.semanticTarget?.role ?? "",
      target.semanticTarget?.identifier ?? "",
      state.value,
      selection,
    ]
    return SHA256.hash(data: Data(components.joined(separator: "\u{1f}").utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
