import Darwin
import Foundation

public enum CodexCredentialBootstrapResult: Equatable, Sendable {
  case installed
  case alreadyPresent
  case sourceUnavailable
}

public enum CodexCredentialBootstrapError: Error, Equatable, Sendable {
  case pathMustBeAbsolute
  case symbolicLinkRejected
  case insecureSource
  case invalidCredentialDocument
  case destinationCreationFailed
  case writeFailed(Int32)
  case commitFailed(Int32)
}

/// Projects only Codex authentication into the product-owned runtime home.
/// Global configuration, MCP servers, skills, history, and logs are never copied.
public struct CodexCredentialBootstrap: Sendable {
  private let maximumBytes = 1_024 * 1_024

  public init() {}

  public func prepare(
    sourceHome: URL,
    destinationHome: URL
  ) throws -> CodexCredentialBootstrapResult {
    guard sourceHome.isFileURL, destinationHome.isFileURL,
      sourceHome.path.hasPrefix("/"), destinationHome.path.hasPrefix("/")
    else {
      throw CodexCredentialBootstrapError.pathMustBeAbsolute
    }
    if isSymbolicLink(sourceHome) || isSymbolicLink(destinationHome) {
      throw CodexCredentialBootstrapError.symbolicLinkRejected
    }
    let source = sourceHome.appendingPathComponent("auth.json")
    let destination = destinationHome.appendingPathComponent("auth.json")
    if source.standardizedFileURL == destination.standardizedFileURL {
      guard fileExists(destination) else { return .sourceUnavailable }
      _ = try readPrivateCredential(at: destination)
      return .alreadyPresent
    }
    if fileExists(destination) {
      _ = try readPrivateCredential(at: destination)
      return .alreadyPresent
    }
    guard fileExists(source) else { return .sourceUnavailable }
    let payload = try readPrivateCredential(at: source)

    do {
      try FileManager.default.createDirectory(
        at: destinationHome,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: destinationHome.path
      )
    } catch {
      throw CodexCredentialBootstrapError.destinationCreationFailed
    }

    let temporary = destinationHome.appendingPathComponent(".auth.\(UUID().uuidString).tmp")
    let descriptor = Darwin.open(
      temporary.path,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      throw CodexCredentialBootstrapError.writeFailed(errno)
    }
    var terminalError: CodexCredentialBootstrapError?
    payload.withUnsafeBytes { rawBuffer in
      guard var pointer = rawBuffer.baseAddress else { return }
      var remaining = rawBuffer.count
      while remaining > 0 {
        let count = Darwin.write(descriptor, pointer, remaining)
        if count < 0 {
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
    guard Darwin.renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
      let commitError = errno
      Darwin.unlink(temporary.path)
      if commitError == EEXIST {
        _ = try readPrivateCredential(at: destination)
        return .alreadyPresent
      }
      throw CodexCredentialBootstrapError.commitFailed(commitError)
    }
    let directoryDescriptor = Darwin.open(destinationHome.path, O_RDONLY | O_CLOEXEC)
    if directoryDescriptor >= 0 {
      _ = Darwin.fsync(directoryDescriptor)
      Darwin.close(directoryDescriptor)
    }
    return .installed
  }

  public func validateCredentialHome(_ home: URL) throws -> Bool {
    guard home.isFileURL, home.path.hasPrefix("/") else {
      throw CodexCredentialBootstrapError.pathMustBeAbsolute
    }
    guard !isSymbolicLink(home) else {
      throw CodexCredentialBootstrapError.symbolicLinkRejected
    }
    let credential = home.appendingPathComponent("auth.json")
    guard fileExists(credential) else { return false }
    _ = try readPrivateCredential(at: credential)
    return true
  }

  private func readPrivateCredential(at url: URL) throws -> Data {
    if isSymbolicLink(url) {
      throw CodexCredentialBootstrapError.symbolicLinkRejected
    }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw CodexCredentialBootstrapError.insecureSource
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
      throw CodexCredentialBootstrapError.insecureSource
    }
    var data = Data()
    data.reserveCapacity(Int(information.st_size))
    var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes))
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw CodexCredentialBootstrapError.insecureSource
      }
      data.append(contentsOf: buffer.prefix(count))
      guard data.count <= maximumBytes else {
        throw CodexCredentialBootstrapError.insecureSource
      }
    }
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      object is [String: Any]
    else {
      throw CodexCredentialBootstrapError.invalidCredentialDocument
    }
    return data
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
