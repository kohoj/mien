import AppKit

/// Optical, monochrome reduction of the two planes in the canonical app icon.
/// Used at control sizes; the full-color icon remains the brand master.
@MainActor
enum MienMark {
  static func image(size: CGFloat = 18, attention: Bool = false) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
      NSGraphicsContext.saveGraphicsState()
      let transform = NSAffineTransform()
      transform.translateX(by: rect.minX + size * 0.08, yBy: rect.minY + size * 0.10)
      transform.scaleX(by: size * 0.84 / 600, yBy: size * 0.80 / 560)
      transform.translateX(by: -210, yBy: -250)
      transform.concat()
      NSColor.black.setFill()
      let warm = NSBezierPath()
      warm.move(to: NSPoint(x: 546, y: 401))
      warm.curve(
        to: NSPoint(x: 364, y: 259), controlPoint1: NSPoint(x: 492, y: 323),
        controlPoint2: NSPoint(x: 414, y: 237))
      warm.curve(
        to: NSPoint(x: 225, y: 569), controlPoint1: NSPoint(x: 266, y: 286),
        controlPoint2: NSPoint(x: 200, y: 417))
      warm.curve(
        to: NSPoint(x: 381, y: 798), controlPoint1: NSPoint(x: 240, y: 703),
        controlPoint2: NSPoint(x: 335, y: 814))
      warm.curve(
        to: NSPoint(x: 397, y: 508), controlPoint1: NSPoint(x: 416, y: 780),
        controlPoint2: NSPoint(x: 374, y: 580))
      warm.curve(
        to: NSPoint(x: 546, y: 401), controlPoint1: NSPoint(x: 421, y: 441),
        controlPoint2: NSPoint(x: 491, y: 392))
      warm.close()
      warm.fill()
      let steel = NSBezierPath()
      steel.move(to: NSPoint(x: 563, y: 417))
      steel.curve(
        to: NSPoint(x: 776, y: 334), controlPoint1: NSPoint(x: 640, y: 357),
        controlPoint2: NSPoint(x: 738, y: 312))
      steel.curve(
        to: NSPoint(x: 794, y: 579), controlPoint1: NSPoint(x: 806, y: 350),
        controlPoint2: NSPoint(x: 813, y: 482))
      steel.curve(
        to: NSPoint(x: 617, y: 790), controlPoint1: NSPoint(x: 773, y: 688),
        controlPoint2: NSPoint(x: 677, y: 770))
      steel.curve(
        to: NSPoint(x: 637, y: 613), controlPoint1: NSPoint(x: 581, y: 807),
        controlPoint2: NSPoint(x: 614, y: 691))
      steel.curve(
        to: NSPoint(x: 563, y: 491), controlPoint1: NSPoint(x: 654, y: 550),
        controlPoint2: NSPoint(x: 616, y: 504))
      steel.close()
      steel.fill()
      NSGraphicsContext.restoreGraphicsState()
      if attention {
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: size - 4, y: 0, width: 3, height: 3)).fill()
      }
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Mien"
    return image
  }
}
