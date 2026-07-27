import Foundation

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
