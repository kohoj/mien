import CoreGraphics
import InteractionShell
import XCTest

final class PanelPlacementTests: XCTestCase {
  func testComposerAvoidsTargetAndClampsToVisibleFrame() {
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let target = CGRect(x: 1040, y: 100, width: 360, height: 120)
    let frame = PanelPlacement().place(
      panelSize: CGSize(width: 390, height: 84),
      pointer: CGPoint(x: 1388, y: 126),
      targetRect: target,
      visibleFrame: visible
    )

    XCTAssertTrue(visible.insetBy(dx: 12, dy: 12).contains(frame))
    XCTAssertTrue(frame.intersection(target).isNull || frame.intersection(target).isEmpty)
  }

  func testCoordinateTransformerHandlesTopLeftToBottomLeftAcrossDisplays() throws {
    let screen = ScreenGeometry(
      displayID: 7,
      coreGraphicsFrame: CGRect(x: 1920, y: -100, width: 1600, height: 1000),
      appKitFrame: CGRect(x: 1920, y: 0, width: 1600, height: 1000),
      visibleFrame: CGRect(x: 1920, y: 24, width: 1600, height: 976)
    )
    let rect = try CoordinateTransformer().appKitRect(
      from: .init(x: 2020, y: 0, width: 400, height: 200),
      displayID: 7,
      screens: [screen]
    )

    XCTAssertEqual(rect, CGRect(x: 2020, y: 700, width: 400, height: 200))
  }

  func testExpandedPanelRemainsInsideVisibleFrame() {
    let visible = CGRect(x: 0, y: 24, width: 900, height: 576)
    let expanded = CGRect(x: 700, y: -30, width: 390, height: 154)

    let frame = PanelPlacement().clamp(expanded, toVisibleFrame: visible)

    XCTAssertTrue(visible.insetBy(dx: 12, dy: 12).contains(frame))
  }
}
