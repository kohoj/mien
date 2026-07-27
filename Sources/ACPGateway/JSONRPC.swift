import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

public struct JSONRPCRequest<Parameters: Encodable & Sendable>: Encodable, Sendable {
  public let jsonrpc = "2.0"
  public let id: Int64
  public let method: String
  public let params: Parameters

  public init(id: Int64, method: String, params: Parameters) {
    self.id = id
    self.method = method
    self.params = params
  }
}

public struct JSONRPCNotification<Parameters: Encodable & Sendable>: Encodable, Sendable {
  public let jsonrpc = "2.0"
  public let method: String
  public let params: Parameters

  public init(method: String, params: Parameters) {
    self.method = method
    self.params = params
  }
}

public struct JSONRPCResponse<Result: Encodable & Sendable>: Encodable, Sendable {
  public let jsonrpc = "2.0"
  public let id: Int64
  public let result: Result

  public init(id: Int64, result: Result) {
    self.id = id
    self.result = result
  }
}

public struct JSONRPCErrorResponse: Encodable, Sendable {
  public struct Body: Encodable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
      self.code = code
      self.message = message
    }
  }

  public let jsonrpc = "2.0"
  public let id: Int64
  public let error: Body

  public init(id: Int64, code: Int, message: String) {
    self.id = id
    error = Body(code: code, message: message)
  }
}

public struct JSONRPCIncomingMessage: Decodable, Equatable, Sendable {
  public struct RPCError: Decodable, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?
  }

  public let jsonrpc: String
  public let id: Int64?
  public let method: String?
  public let params: JSONValue?
  public let result: JSONValue?
  public let error: RPCError?
}

public enum NDJSONRPCCodecError: Error, Equatable, Sendable {
  case emptyLine
  case invalidJSON
  case invalidVersion
}

public struct NDJSONRPCCodec: Sendable {
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init() {
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    decoder = JSONDecoder()
  }

  public func encode<Value: Encodable>(_ value: Value) throws -> Data {
    var data = try encoder.encode(value)
    data.append(0x0A)
    return data
  }

  public func decode(_ line: Data) throws -> JSONRPCIncomingMessage {
    let trimmed = line.drop(while: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D })
    guard !trimmed.isEmpty else { throw NDJSONRPCCodecError.emptyLine }
    let message: JSONRPCIncomingMessage
    do {
      message = try decoder.decode(JSONRPCIncomingMessage.self, from: Data(trimmed))
    } catch {
      throw NDJSONRPCCodecError.invalidJSON
    }
    guard message.jsonrpc == "2.0" else { throw NDJSONRPCCodecError.invalidVersion }
    return message
  }
}
