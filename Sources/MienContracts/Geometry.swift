import Foundation

public struct ScreenPoint: Codable, Equatable, Hashable, Sendable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }

  public var isFinite: Bool { x.isFinite && y.isFinite }
}

public struct ScreenSize: Codable, Equatable, Hashable, Sendable {
  public let width: Double
  public let height: Double

  public init(width: Double, height: Double) {
    self.width = width
    self.height = height
  }

  public var isValid: Bool {
    width.isFinite && height.isFinite && width > 0 && height > 0
  }
}

public struct ScreenRect: Codable, Equatable, Hashable, Sendable {
  public let origin: ScreenPoint
  public let size: ScreenSize

  public init(origin: ScreenPoint, size: ScreenSize) {
    self.origin = origin
    self.size = size
  }

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.init(
      origin: ScreenPoint(x: x, y: y),
      size: ScreenSize(width: width, height: height)
    )
  }

  public var isValid: Bool { origin.isFinite && size.isValid }

  public func contains(_ point: ScreenPoint) -> Bool {
    guard isValid, point.isFinite else { return false }
    return point.x >= origin.x
      && point.y >= origin.y
      && point.x <= origin.x + size.width
      && point.y <= origin.y + size.height
  }
}
