import AppKit
import PermissionKernel

@MainActor
struct ReadinessActions {
  let connect: () -> Void
  let refreshModels: () -> Void
  let selectModel: (String?) -> Void
  let request: (DesktopPermission, NSView) -> Void
  let finish: () -> Void
  let showSetup: () -> Void
  let showSettings: () -> Void

  static let preview = ReadinessActions(
    connect: {}, refreshModels: {}, selectModel: { _ in }, request: { _, _ in },
    finish: {}, showSetup: {}, showSettings: {})
}

@MainActor
protocol ReadinessContent: AnyObject {
  var controller: NSViewController { get }
  func apply(_ snapshot: MienReadinessSnapshot)
  func focus(_ permission: DesktopPermission?)
  func showNavigationError(for permission: DesktopPermission)
}

extension ReadinessContent where Self: NSViewController {
  var controller: NSViewController { self }
}

enum ReadinessMode {
  case setup
  case settings

  var contentSize: NSSize {
    switch self {
    case .setup: NSSize(width: 480, height: 340)
    case .settings: NSSize(width: 520, height: 400)
    }
  }
}

@MainActor
final class ReadinessWindow: NSWindow {
  var onSettings: (() -> Void)?

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.charactersIgnoringModifiers == ",",
      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
    {
      onSettings?()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

@MainActor
enum ReadinessLayout {
  static func label(
    _ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
    secondary: Bool = false
  ) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = secondary ? .secondaryLabelColor : .labelColor
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }

  static func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat = 8) -> NSStackView
  {
    let stack = NSStackView(views: views)
    stack.orientation = vertical ? .vertical : .horizontal
    stack.alignment = vertical ? .leading : .centerY
    stack.spacing = spacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }

  static func separator() -> NSView {
    let line = NSBox()
    line.boxType = .separator
    line.translatesAutoresizingMaskIntoConstraints = false
    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return line
  }
}
