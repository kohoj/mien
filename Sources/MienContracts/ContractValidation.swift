import Foundation

public enum ContractValidationError: Error, Equatable, Sendable {
  case empty(String)
  case invalid(String)
  case expired(String)
  case inconsistent(String)
  case unauthorized(String)
}

extension ContractValidationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .empty(let field): "Required field is empty: \(field)"
    case .invalid(let field): "Field is invalid: \(field)"
    case .expired(let field): "Value has expired: \(field)"
    case .inconsistent(let reason): "Contract is inconsistent: \(reason)"
    case .unauthorized(let reason): "Contract is unauthorized: \(reason)"
    }
  }
}

public protocol ContractValidating: Sendable {
  func validate(now: Date) throws
}

extension ContractValidating {
  public func validate() throws {
    try validate(now: Date())
  }
}
