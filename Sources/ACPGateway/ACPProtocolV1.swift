import Foundation
import MienContracts

public enum ACPProtocolV1 {
  public static let version: UInt16 = 1
}

public struct ACPImplementation: Codable, Equatable, Sendable {
  public let name: String
  public let title: String?
  public let version: String

  public init(name: String, title: String?, version: String) {
    self.name = name
    self.title = title
    self.version = version
  }
}

public struct ACPFileSystemCapabilities: Codable, Equatable, Sendable {
  public let readTextFile: Bool
  public let writeTextFile: Bool

  public init(readTextFile: Bool, writeTextFile: Bool) {
    self.readTextFile = readTextFile
    self.writeTextFile = writeTextFile
  }
}

public struct ACPClientCapabilities: Codable, Equatable, Sendable {
  public let fs: ACPFileSystemCapabilities
  public let terminal: Bool

  public init(
    fs: ACPFileSystemCapabilities = ACPFileSystemCapabilities(
      readTextFile: false,
      writeTextFile: false
    ),
    terminal: Bool = false
  ) {
    self.fs = fs
    self.terminal = terminal
  }
}

public struct ACPInitializeParameters: Codable, Equatable, Sendable {
  public let protocolVersion: UInt16
  public let clientCapabilities: ACPClientCapabilities
  public let clientInfo: ACPImplementation

  public init(
    protocolVersion: UInt16 = ACPProtocolV1.version,
    clientCapabilities: ACPClientCapabilities,
    clientInfo: ACPImplementation
  ) {
    self.protocolVersion = protocolVersion
    self.clientCapabilities = clientCapabilities
    self.clientInfo = clientInfo
  }
}

public struct ACPNewSessionParameters: Codable, Equatable, Sendable {
  public let cwd: String
  public let additionalDirectories: [String]
  public let mcpServers: [JSONValue]

  public init(cwd: String, additionalDirectories: [String], mcpServers: [JSONValue]) {
    self.cwd = cwd
    self.additionalDirectories = additionalDirectories
    self.mcpServers = mcpServers
  }

  public func validate() throws {
    guard cwd.hasPrefix("/") else {
      throw ACPConfigurationError.invalidWorkingDirectory
    }
    guard additionalDirectories.allSatisfy({ $0.hasPrefix("/") }) else {
      throw ACPConfigurationError.invalidAdditionalDirectory
    }
  }
}

public struct ACPInitializeResult: Decodable, Equatable, Sendable {
  public let protocolVersion: UInt16
  public let agentCapabilities: JSONValue?
  public let authMethods: [JSONValue]?
  public let agentInfo: ACPImplementation?
}

public struct ACPNewSessionResult: Decodable, Equatable, Sendable {
  public let sessionId: String
  public let configOptions: [ACPSessionConfigOption]?
}

public struct ACPSessionConfigOption: Decodable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let description: String?
  public let category: String?
  public let type: String
  public let currentValue: JSONValue?
  public let options: JSONValue?
}

public struct ACPSetSessionConfigOptionParameters: Encodable, Equatable, Sendable {
  public let sessionId: String
  public let configId: String
  public let value: String

  public init(sessionId: String, configId: String, value: String) {
    self.sessionId = sessionId
    self.configId = configId
    self.value = value
  }
}

public struct ACPSetSessionConfigOptionResult: Decodable, Equatable, Sendable {
  public let configOptions: [ACPSessionConfigOption]
}

public struct ACPAgentModelConfiguration: Equatable, Sendable {
  public let configID: String
  public let catalog: AgentModelCatalog

  public init(configID: String, catalog: AgentModelCatalog) {
    self.configID = configID
    self.catalog = catalog
  }
}

public enum ACPModelConfigurationError: Error, Equatable, Sendable {
  case unavailable
  case malformed
}

extension ACPNewSessionResult {
  public func agentModelConfiguration() throws -> ACPAgentModelConfiguration {
    try Self.agentModelConfiguration(from: configOptions)
  }

  fileprivate static func agentModelConfiguration(
    from configOptions: [ACPSessionConfigOption]?
  ) throws -> ACPAgentModelConfiguration {
    guard let configOptions else { throw ACPModelConfigurationError.unavailable }
    let candidates = configOptions.filter { $0.category == "model" }
    guard candidates.count == 1 else { throw ACPModelConfigurationError.unavailable }
    let configuration = candidates[0]
    guard configuration.type == "select",
      !configuration.id.isEmpty,
      case .string(let currentModelID)? = configuration.currentValue,
      case .array(let rawOptions)? = configuration.options
    else {
      throw ACPModelConfigurationError.malformed
    }

    let options = try rawOptions.map { value -> AgentModelOption in
      guard case .object(let object) = value,
        case .string(let id)? = object["value"],
        case .string(let name)? = object["name"]
      else {
        throw ACPModelConfigurationError.malformed
      }
      let description: String?
      switch object["description"] {
      case .some(.string(let value)): description = value
      case .some(.null), .none: description = nil
      default: throw ACPModelConfigurationError.malformed
      }
      return AgentModelOption(id: id, name: name, description: description)
    }
    let catalog = AgentModelCatalog(currentModelID: currentModelID, options: options)
    do {
      try catalog.validate()
    } catch {
      throw ACPModelConfigurationError.malformed
    }
    return ACPAgentModelConfiguration(configID: configuration.id, catalog: catalog)
  }
}

extension ACPSetSessionConfigOptionResult {
  public func agentModelConfiguration() throws -> ACPAgentModelConfiguration {
    try ACPNewSessionResult.agentModelConfiguration(from: configOptions)
  }
}

public enum ACPNegotiationError: Error, Equatable, Sendable {
  case unsupportedProtocolVersion(UInt16)
}

public struct ACPNegotiationPolicy: Sendable {
  public init() {}

  public func validate(_ result: ACPInitializeResult) throws {
    guard result.protocolVersion == ACPProtocolV1.version else {
      throw ACPNegotiationError.unsupportedProtocolVersion(result.protocolVersion)
    }
  }
}

/// A deliberately narrow projection of ACP session updates for user-visible
/// progress. Message text and raw tool input/output never cross this boundary:
/// Mien can show that the Agent is thinking or using a named tool without
/// turning private reasoning or untrusted command output into UI state.
public struct ACPAgentActivityUpdate: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case thinking
    case tool
    case plan
  }

  public enum Status: Equatable, Sendable {
    case active
    case completed
    case failed
  }

  public let sessionID: String
  public let id: String
  public let kind: Kind
  public let toolName: String?
  public let title: String?
  public let status: Status

  public init(
    sessionID: String,
    id: String,
    kind: Kind,
    toolName: String? = nil,
    title: String?,
    status: Status
  ) {
    self.sessionID = sessionID
    self.id = id
    self.kind = kind
    self.toolName = toolName
    self.title = title
    self.status = status
  }

  public static func project(_ message: JSONRPCIncomingMessage) -> [Self] {
    guard message.method == "session/update",
      case .object(let parameters)? = message.params,
      case .string(let sessionID)? = parameters["sessionId"],
      case .object(let update)? = parameters["update"],
      case .string(let updateKind)? = update["sessionUpdate"]
    else {
      return []
    }

    switch updateKind {
    case "agent_thought_chunk":
      let messageID = update.string(for: "messageId") ?? "agent-thinking"
      return [
        Self(
          sessionID: sessionID,
          id: "thought:\(messageID)",
          kind: .thinking,
          title: nil,
          status: Self.status(from: update.string(for: "status"))
        )
      ]
    case "tool_call", "tool_call_update":
      guard let toolCallID = update.string(for: "toolCallId") else { return [] }
      return [
        Self(
          sessionID: sessionID,
          id: "tool:\(toolCallID)",
          kind: .tool,
          toolName: update.string(for: "name"),
          title: update.string(for: "title") ?? update.string(for: "name"),
          status: Self.status(from: update.string(for: "status"))
        )
      ]
    case "plan":
      guard case .array(let entries)? = update["entries"] else { return [] }
      return entries.enumerated().compactMap { index, value in
        guard case .object(let entry) = value,
          case .string(let content)? = entry["content"]
        else {
          return nil
        }
        return Self(
          sessionID: sessionID,
          id: "plan:\(index)",
          kind: .plan,
          title: content,
          status: Self.status(from: entry.string(for: "status"))
        )
      }
    default:
      return []
    }
  }

  private static func status(from rawValue: String?) -> Status {
    switch rawValue {
    case "completed": .completed
    case "failed": .failed
    default: .active
    }
  }
}

extension Dictionary where Key == String, Value == JSONValue {
  fileprivate func string(for key: String) -> String? {
    guard case .string(let value)? = self[key] else { return nil }
    return value
  }
}
