import Foundation

public struct AgentModelOption: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let description: String?

  public init(id: String, name: String, description: String? = nil) {
    self.id = id
    self.name = name
    self.description = description
  }

  public func validate() throws {
    guard !id.isEmpty, !name.isEmpty else {
      throw ContractValidationError.empty("agentModelOption")
    }
  }
}

/// The model choices advertised by the connected Agent for one newly created
/// session. This is live capability data, not a locally maintained model list.
public struct AgentModelCatalog: Codable, Equatable, Sendable {
  public let currentModelID: String
  public let options: [AgentModelOption]

  public init(currentModelID: String, options: [AgentModelOption]) {
    self.currentModelID = currentModelID
    self.options = options
  }

  public func validate() throws {
    guard !currentModelID.isEmpty, !options.isEmpty else {
      throw ContractValidationError.empty("agentModelCatalog")
    }
    for option in options {
      try option.validate()
    }
    guard Set(options.map(\.id)).count == options.count,
      options.contains(where: { $0.id == currentModelID })
    else {
      throw ContractValidationError.inconsistent(
        "current model must identify one unique advertised option"
      )
    }
  }

  public func contains(_ modelID: String) -> Bool {
    options.contains(where: { $0.id == modelID })
  }

  public func option(for modelID: String) -> AgentModelOption? {
    options.first(where: { $0.id == modelID })
  }
}
