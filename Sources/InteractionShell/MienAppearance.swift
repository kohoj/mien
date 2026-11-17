import AppKit

/// The icon's graphite, warm white and ultramarine translated into functional
/// surfaces. Native controls and the offline typesetter share this one owner.
@MainActor
enum MienAppearance {
  static let paper = NSColor(name: "MienReadingSurface") { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(srgbRed: 0.105, green: 0.11, blue: 0.12, alpha: 1)
      : NSColor(srgbRed: 0.978, green: 0.974, blue: 0.965, alpha: 1)
  }
  static let accent = NSColor(srgbRed: 23 / 255, green: 72 / 255, blue: 184 / 255, alpha: 1)
  static let accentInk = NSColor.white

  static func inputSurface(containing content: NSView) -> NSView {
    let surface = MienInputSurfaceView()
    surface.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    surface.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 12),
      content.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -6),
      content.topAnchor.constraint(equalTo: surface.topAnchor, constant: 6),
      content.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -6),
    ])
    return surface
  }
}

@MainActor
private final class MienInputSurfaceView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    let shape = NSBezierPath(
      roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
    NSColor.textBackgroundColor.withAlphaComponent(0.55).setFill()
    shape.fill()
    (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
      ? NSColor.labelColor : NSColor.separatorColor).setStroke()
    shape.lineWidth = 0.5
    shape.stroke()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

@MainActor
final class MienPaperView: NSView {
  override var isOpaque: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    MienAppearance.paper.setFill()
    dirtyRect.fill()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}

/// Native button behavior, focus and AX semantics with Mien's single accent.
/// Borderless NSButton drawing avoids OS bezel colors varying by window focus.
@MainActor
final class MienAccentButton: NSButton {
  override init(frame: NSRect) {
    super.init(frame: frame)
    isBordered = false
    contentTintColor = MienAppearance.accentInk
    focusRingType = .exterior
    font = .systemFont(ofSize: 13, weight: .medium)
  }

  required init?(coder: NSCoder) { nil }

  override var isEnabled: Bool {
    didSet {
      contentTintColor = isEnabled ? MienAppearance.accentInk : .tertiaryLabelColor
      needsDisplay = true
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    let color = isEnabled ? MienAppearance.accent : NSColor.quaternaryLabelColor
    (cell?.isHighlighted == true ? color.withAlphaComponent(0.72) : color).setFill()
    let shape = NSBezierPath(
      roundedRect: bounds, xRadius: 8, yRadius: 8)
    shape.fill()
    if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
      NSColor.labelColor.setStroke()
      shape.lineWidth = 1
      shape.stroke()
    }
    super.draw(dirtyRect)
  }

  override var focusRingMaskBounds: NSRect { bounds }
  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
  }
}
