import CoreGraphics
import Foundation

public struct PanelPlacement: Sendable {
  public let edgeInset: CGFloat
  public let pointerGap: CGFloat

  public init(edgeInset: CGFloat = 12, pointerGap: CGFloat = 14) {
    self.edgeInset = max(0, edgeInset)
    self.pointerGap = max(0, pointerGap)
  }

  public func place(
    panelSize: CGSize,
    pointer: CGPoint,
    targetRect: CGRect,
    visibleFrame: CGRect
  ) -> CGRect {
    let candidates = [
      CGPoint(
        x: pointer.x - panelSize.width / 2,
        y: targetRect.minY - panelSize.height - pointerGap
      ),
      CGPoint(
        x: pointer.x - panelSize.width / 2,
        y: targetRect.maxY + pointerGap
      ),
      CGPoint(
        x: targetRect.minX - panelSize.width - pointerGap,
        y: pointer.y - panelSize.height / 2
      ),
      CGPoint(
        x: targetRect.maxX + pointerGap,
        y: pointer.y - panelSize.height / 2
      ),
      CGPoint(x: pointer.x + pointerGap, y: pointer.y - panelSize.height - pointerGap),
      CGPoint(x: pointer.x + pointerGap, y: pointer.y + pointerGap),
      CGPoint(
        x: pointer.x - panelSize.width - pointerGap, y: pointer.y - panelSize.height - pointerGap),
      CGPoint(x: pointer.x - panelSize.width - pointerGap, y: pointer.y + pointerGap),
    ].map { CGRect(origin: $0, size: panelSize) }

    let usable = visibleFrame.insetBy(dx: edgeInset, dy: edgeInset)
    let best =
      candidates.min { lhs, rhs in
        score(lhs, targetRect: targetRect, usable: usable)
          < score(rhs, targetRect: targetRect, usable: usable)
      } ?? CGRect(origin: pointer, size: panelSize)
    return clamped(best, to: usable)
  }

  public func clamp(_ frame: CGRect, toVisibleFrame visibleFrame: CGRect) -> CGRect {
    clamped(frame, to: visibleFrame.insetBy(dx: edgeInset, dy: edgeInset))
  }

  private func score(_ frame: CGRect, targetRect: CGRect, usable: CGRect) -> CGFloat {
    let targetOcclusion = frame.intersection(targetRect).area
    let outside = frame.area - frame.intersection(usable).area
    return targetOcclusion * 10 + outside * 100
  }

  private func clamped(_ frame: CGRect, to bounds: CGRect) -> CGRect {
    guard bounds.width >= frame.width, bounds.height >= frame.height else {
      return CGRect(origin: bounds.origin, size: frame.size)
    }
    return CGRect(
      x: min(max(frame.minX, bounds.minX), bounds.maxX - frame.width),
      y: min(max(frame.minY, bounds.minY), bounds.maxY - frame.height),
      width: frame.width,
      height: frame.height
    )
  }
}

extension CGRect {
  fileprivate var area: CGFloat { isNull ? 0 : max(0, width) * max(0, height) }
}
