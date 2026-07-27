import AppKit
import CoreGraphics
import Foundation
import MienContracts

public enum CoordinateTransformerError: Error, Equatable, Sendable {
  case displayUnavailable(UInt32)
}

public struct CoordinateTransformer: Sendable {
  public init() {}

  public func appKitRect(
    from rect: ScreenRect,
    displayID: UInt32,
    screens: [ScreenGeometry]
  ) throws -> CGRect {
    guard let screen = screens.first(where: { $0.displayID == displayID }) else {
      throw CoordinateTransformerError.displayUnavailable(displayID)
    }
    let localX = rect.origin.x - screen.coreGraphicsFrame.minX
    let localYFromTop = rect.origin.y - screen.coreGraphicsFrame.minY
    return CGRect(
      x: screen.appKitFrame.minX + localX,
      y: screen.appKitFrame.maxY - localYFromTop - rect.size.height,
      width: rect.size.width,
      height: rect.size.height
    )
  }

  public func appKitPoint(
    from point: ScreenPoint,
    displayID: UInt32,
    screens: [ScreenGeometry]
  ) throws -> CGPoint {
    guard let screen = screens.first(where: { $0.displayID == displayID }) else {
      throw CoordinateTransformerError.displayUnavailable(displayID)
    }
    return CGPoint(
      x: screen.appKitFrame.minX + point.x - screen.coreGraphicsFrame.minX,
      y: screen.appKitFrame.maxY - (point.y - screen.coreGraphicsFrame.minY)
    )
  }
}

public struct ScreenGeometry: Equatable, Sendable {
  public let displayID: UInt32
  public let coreGraphicsFrame: CGRect
  public let appKitFrame: CGRect
  public let visibleFrame: CGRect

  public init(
    displayID: UInt32,
    coreGraphicsFrame: CGRect,
    appKitFrame: CGRect,
    visibleFrame: CGRect
  ) {
    self.displayID = displayID
    self.coreGraphicsFrame = coreGraphicsFrame
    self.appKitFrame = appKitFrame
    self.visibleFrame = visibleFrame
  }

  @MainActor
  public static var current: [ScreenGeometry] {
    NSScreen.screens.compactMap { screen in
      guard
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
          as? NSNumber
      else {
        return nil
      }
      let displayID = number.uint32Value
      return ScreenGeometry(
        displayID: displayID,
        coreGraphicsFrame: CGDisplayBounds(displayID),
        appKitFrame: screen.frame,
        visibleFrame: screen.visibleFrame
      )
    }
  }
}
