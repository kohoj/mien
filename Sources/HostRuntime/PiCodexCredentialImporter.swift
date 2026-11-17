import Darwin
import Foundation

public enum PiCodexCredentialImportResult: Equatable, Sendable {
  case installed
  case alreadyPresent
  case sourceUnavailable
}

public enum PiCodexCredentialImportError: Error, Equatable, Sendable {
  case pathMustBeAbsolute
  case symbolicLinkRejected
  case insecureCredentialFile
  case invalidCodexCredential
  case invalidPiCredential
  case destinationCreationFailed
  case writeFailed(Int32)
  case commitFailed(Int32)
}

/// Imports only an existing Codex CLI subscription credential into Mien's
/// owner-only Pi store. No CLI configuration, history, MCP server, skill, or
/// environment is inherited. The two tools use different documented JSON
/// schemas, so copying the source file byte-for-byte would leave Pi appearing
/// connected while its model catalog is empty.
public struct PiCodexCredentialImporter: Sendable {
  private let maximumBytes = 256 * 1_024

  public init() {}

  public func prepare(
    codexHome: URL,
    piHome: URL
  ) throws -> PiCodexCredentialImportResult {
    guard codexHome.isFileURL, piHome.isFileURL,
      codexHome.path.hasPrefix("/"), piHome.path.hasPrefix("/")
    else {
      throw PiCodexCredentialImportError.pathMustBeAbsolute
    }
    guard !isSymbolicLink(codexHome), !isSymbolicLink(piHome) else {
      throw PiCodexCredentialImportError.symbolicLinkRejected
    }

    let source = codexHome.appendingPathComponent("auth.json")
    let destination = piHome.appendingPathComponent("auth.json")
    var destinationObject: [String: Any] = [:]
    if fileExists(destination) {
      destinationObject = try readPrivateObject(at: destination)
      if Self.isValidPiCodexCredential(destinationObject["openai-codex"]) {
        return .alreadyPresent
      }
    }
    guard fileExists(source) else { return .sourceUnavailable }
    let sourceObject = try readPrivateObject(at: source)
    let credential = try Self.convert(sourceObject)
    destinationObject["openai-codex"] = credential
    let payload: Data
    do {
      payload = try JSONSerialization.data(
        withJSONObject: destinationObject,
        options: [.sortedKeys]
      )
    } catch {
      throw PiCodexCredentialImportError.invalidPiCredential
    }
    try commit(payload, to: destination, home: piHome)
    return .installed
  }

  public func validate(piHome: URL) throws -> Bool {
    guard piHome.isFileURL, piHome.path.hasPrefix("/") else {
      throw PiCodexCredentialImportError.pathMustBeAbsolute
    }
    guard !isSymbolicLink(piHome) else {
      throw PiCodexCredentialImportError.symbolicLinkRejected
    }
    let destination = piHome.appendingPathComponent("auth.json")
    guard fileExists(destination) else { return false }
    return Self.isValidPiCodexCredential(try readPrivateObject(at: destination)["openai-codex"])
  }

  private static func convert(_ object: [String: Any]) throws -> [String: Any] {
    guard object["auth_mode"] as? String == "chatgpt",
      let tokens = object["tokens"] as? [String: Any],
      let access = tokens["access_token"] as? String,
      let refresh = tokens["refresh_token"] as? String,
      let accountID = tokens["account_id"] as? String,
      !access.isEmpty, !refresh.isEmpty, !accountID.isEmpty,
      let expires = jwtExpirationMilliseconds(access),
      jwtAccountID(access) == accountID
    else {
      throw PiCodexCredentialImportError.invalidCodexCredential
    }
    return [
      "type": "oauth",
      "access": access,
      "refresh": refresh,
      "expires": expires,
      "accountId": accountID,
    ]
  }

  private static func isValidPiCodexCredential(_ value: Any?) -> Bool {
    guard let credential = value as? [String: Any],
      credential["type"] as? String == "oauth",
      let access = credential["access"] as? String,
      let refresh = credential["refresh"] as? String,
      let accountID = credential["accountId"] as? String,
      let expires = credential["expires"] as? NSNumber
    else {
      return false
    }
    return !access.isEmpty && !refresh.isEmpty && !accountID.isEmpty && expires.int64Value > 0
  }

  private static func jwtExpirationMilliseconds(_ token: String) -> Int64? {
    guard let payload = jwtPayload(token), let seconds = payload["exp"] as? NSNumber else {
      return nil
    }
    let milliseconds = seconds.doubleValue * 1_000
    guard milliseconds.isFinite, milliseconds > 0, milliseconds <= Double(Int64.max) else {
      return nil
    }
    return Int64(milliseconds)
  }

  private static func jwtAccountID(_ token: String) -> String? {
    guard let payload = jwtPayload(token),
      let auth = payload["https://api.openai.com/auth"] as? [String: Any]
    else {
      return nil
    }
    return auth["chatgpt_account_id"] as? String
  }

  private static func jwtPayload(_ token: String) -> [String: Any]? {
    let segments = token.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3 else { return nil }
    var encoded = String(segments[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded.append(String(repeating: "=", count: (4 - encoded.count % 4) % 4))
    guard let data = Data(base64Encoded: encoded),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return object
  }

  private func commit(_ payload: Data, to destination: URL, home: URL) throws {
    guard payload.count <= maximumBytes else {
      throw PiCodexCredentialImportError.invalidPiCredential
    }
    do {
      try FileManager.default.createDirectory(
        at: home,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: home.path
      )
    } catch {
      throw PiCodexCredentialImportError.destinationCreationFailed
    }

    let temporary = home.appendingPathComponent(".auth.\(UUID().uuidString).tmp")
    let descriptor = Darwin.open(
      temporary.path,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      throw PiCodexCredentialImportError.writeFailed(errno)
    }
    var terminalError: PiCodexCredentialImportError?
    payload.withUnsafeBytes { rawBuffer in
      guard var pointer = rawBuffer.baseAddress else { return }
      var remaining = rawBuffer.count
      while remaining > 0 {
        let count = Darwin.write(descriptor, pointer, remaining)
        if count < 0 {
          if errno == EINTR { continue }
          terminalError = .writeFailed(errno)
          return
        }
        pointer = pointer.advanced(by: count)
        remaining -= count
      }
    }
    if terminalError == nil, Darwin.fsync(descriptor) != 0 {
      terminalError = .writeFailed(errno)
    }
    Darwin.close(descriptor)
    if let terminalError {
      Darwin.unlink(temporary.path)
      throw terminalError
    }
    guard Darwin.rename(temporary.path, destination.path) == 0 else {
      let commitError = errno
      Darwin.unlink(temporary.path)
      throw PiCodexCredentialImportError.commitFailed(commitError)
    }
    let directoryDescriptor = Darwin.open(home.path, O_RDONLY | O_CLOEXEC)
    if directoryDescriptor >= 0 {
      _ = Darwin.fsync(directoryDescriptor)
      Darwin.close(directoryDescriptor)
    }
  }

  private func readPrivateObject(at url: URL) throws -> [String: Any] {
    guard !isSymbolicLink(url) else {
      throw PiCodexCredentialImportError.symbolicLinkRejected
    }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw PiCodexCredentialImportError.insecureCredentialFile
    }
    defer { Darwin.close(descriptor) }
    var information = stat()
    guard Darwin.fstat(descriptor, &information) == 0,
      (information.st_mode & S_IFMT) == S_IFREG,
      information.st_uid == Darwin.getuid(),
      (information.st_mode & 0o077) == 0,
      information.st_size > 0,
      information.st_size <= maximumBytes
    else {
      throw PiCodexCredentialImportError.insecureCredentialFile
    }
    var data = Data()
    data.reserveCapacity(Int(information.st_size))
    var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes))
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw PiCodexCredentialImportError.insecureCredentialFile
      }
      data.append(contentsOf: buffer.prefix(count))
      guard data.count <= maximumBytes else {
        throw PiCodexCredentialImportError.insecureCredentialFile
      }
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw PiCodexCredentialImportError.invalidCodexCredential
    }
    return object
  }

  private func fileExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  private func isSymbolicLink(_ url: URL) -> Bool {
    var information = stat()
    guard lstat(url.path, &information) == 0 else { return false }
    return (information.st_mode & S_IFMT) == S_IFLNK
  }
}
