import CryptoKit
import Darwin
import Foundation
import MienContracts

public struct ArtifactDescriptor: Sendable {
  public let taskID: UUID
  public let targetLeaseID: UUID
  public let kind: ContextArtifactKind
  public let provider: ContextProviderKind
  public let providerVersion: String
  public let coherenceGroup: UUID
  public let scope: ContextScope
  public let mediaType: String
  public let sourceTrust: SourceTrust
  public let sensitivity: Sensitivity
  public let confidence: Double
  public let complete: Bool
  public let retention: ArtifactRetention

  public init(
    taskID: UUID,
    targetLeaseID: UUID,
    kind: ContextArtifactKind,
    provider: ContextProviderKind,
    providerVersion: String,
    coherenceGroup: UUID,
    scope: ContextScope,
    mediaType: String,
    sourceTrust: SourceTrust,
    sensitivity: Sensitivity,
    confidence: Double,
    complete: Bool,
    retention: ArtifactRetention
  ) {
    self.taskID = taskID
    self.targetLeaseID = targetLeaseID
    self.kind = kind
    self.provider = provider
    self.providerVersion = providerVersion
    self.coherenceGroup = coherenceGroup
    self.scope = scope
    self.mediaType = mediaType
    self.sourceTrust = sourceTrust
    self.sensitivity = sensitivity
    self.confidence = confidence
    self.complete = complete
    self.retention = retention
  }
}

public enum ArtifactStoreError: Error, Equatable, Sendable {
  case rootMustBeAbsolute
  case symbolicLinkRejected
  case createDirectoryFailed
  case createFileFailed(Int32)
  case writeFailed(Int32)
  case commitFailed(Int32)
  case artifactNotFound
  case artifactIdentityMismatch
  case artifactCorrupted
  case cleanupFailed
}

public actor PrivateArtifactStore: ContextArtifactReading {
  private let rootURL: URL
  private var records: [UUID: ContextArtifact] = [:]

  public init(rootURL: URL) throws {
    guard rootURL.isFileURL, rootURL.path.hasPrefix("/") else {
      throw ArtifactStoreError.rootMustBeAbsolute
    }
    if Self.isSymbolicLink(rootURL) {
      throw ArtifactStoreError.symbolicLinkRejected
    }
    do {
      try FileManager.default.createDirectory(
        at: rootURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: rootURL.path
      )
    } catch {
      throw ArtifactStoreError.createDirectoryFailed
    }
    let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
    do {
      for child in try FileManager.default.contentsOfDirectory(
        at: resolvedRoot,
        includingPropertiesForKeys: [.isSymbolicLinkKey],
        options: []
      ) {
        try FileManager.default.removeItem(at: child)
      }
    } catch {
      throw ArtifactStoreError.createDirectoryFailed
    }
    self.rootURL = resolvedRoot
  }

  public func store(
    _ data: Data,
    descriptor: ArtifactDescriptor,
    now: Date = Date()
  ) throws -> ContextArtifact {
    let artifactID = UUID()
    let taskDirectory = rootURL.appendingPathComponent(
      descriptor.taskID.uuidString,
      isDirectory: true
    )
    if Self.isSymbolicLink(taskDirectory) {
      throw ArtifactStoreError.symbolicLinkRejected
    }
    do {
      try FileManager.default.createDirectory(
        at: taskDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: taskDirectory.path
      )
    } catch {
      throw ArtifactStoreError.createDirectoryFailed
    }

    let fileExtension = Self.fileExtension(for: descriptor.mediaType)
    let finalURL =
      taskDirectory
      .appendingPathComponent(artifactID.uuidString)
      .appendingPathExtension(fileExtension)
    let temporaryURL =
      taskDirectory
      .appendingPathComponent(".\(artifactID.uuidString).partial")
    try Self.writePrivateAtomically(data, temporaryURL: temporaryURL, finalURL: finalURL)

    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let artifact = ContextArtifact(
      id: artifactID,
      taskID: descriptor.taskID,
      targetLeaseID: descriptor.targetLeaseID,
      kind: descriptor.kind,
      provider: descriptor.provider,
      providerVersion: descriptor.providerVersion,
      capturedAt: now,
      coherenceGroup: descriptor.coherenceGroup,
      scope: descriptor.scope,
      mediaType: descriptor.mediaType,
      privateURI: finalURL,
      byteCount: data.count,
      contentDigest: digest,
      sourceTrust: descriptor.sourceTrust,
      sensitivity: descriptor.sensitivity,
      confidence: descriptor.confidence,
      complete: descriptor.complete,
      retention: descriptor.retention
    )
    try artifact.validate(now: now)
    records[artifact.id] = artifact
    return artifact
  }

  public func artifact(id: UUID, now: Date = Date()) throws -> ContextArtifact {
    guard let artifact = records[id], now < artifact.retention.expiresAt else {
      throw ArtifactStoreError.artifactNotFound
    }
    return artifact
  }

  public func readArtifact(
    id: UUID,
    taskID: UUID,
    targetLeaseID: UUID,
    now: Date = Date()
  ) async throws -> Data {
    let artifact = try artifact(id: id, now: now)
    guard artifact.taskID == taskID, artifact.targetLeaseID == targetLeaseID else {
      throw ArtifactStoreError.artifactIdentityMismatch
    }
    let resolvedURL = artifact.privateURI.resolvingSymlinksInPath().standardizedFileURL
    guard resolvedURL.path.hasPrefix(rootURL.path + "/"),
      !Self.isSymbolicLink(artifact.privateURI),
      let data = try? Data(contentsOf: resolvedURL, options: [.mappedIfSafe])
    else {
      throw ArtifactStoreError.artifactNotFound
    }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard data.count == artifact.byteCount, digest == artifact.contentDigest else {
      throw ArtifactStoreError.artifactCorrupted
    }
    return data
  }

  public func remove(id: UUID) throws {
    guard let artifact = records.removeValue(forKey: id) else {
      throw ArtifactStoreError.artifactNotFound
    }
    try FileManager.default.removeItem(at: artifact.privateURI)
  }

  @discardableResult
  public func removeArtifacts(
    for taskID: UUID,
    deleteAfterTaskOnly: Bool = true
  ) throws -> [UUID] {
    let matches = records.values.filter {
      $0.taskID == taskID && (!deleteAfterTaskOnly || $0.retention.deleteAfterTask)
    }
    var removed: [UUID] = []
    for artifact in matches {
      if FileManager.default.fileExists(atPath: artifact.privateURI.path) {
        do {
          try FileManager.default.removeItem(at: artifact.privateURI)
        } catch {
          throw ArtifactStoreError.cleanupFailed
        }
      }
      guard !FileManager.default.fileExists(atPath: artifact.privateURI.path) else {
        throw ArtifactStoreError.cleanupFailed
      }
      records.removeValue(forKey: artifact.id)
      removed.append(artifact.id)
    }
    let directory = rootURL.appendingPathComponent(taskID.uuidString, isDirectory: true)
    if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
      do {
        try FileManager.default.removeItem(at: directory)
      } catch {
        throw ArtifactStoreError.cleanupFailed
      }
    }
    return removed
  }

  @discardableResult
  public func purgeExpired(now: Date = Date()) -> [UUID] {
    let expired = records.values.filter { now >= $0.retention.expiresAt }
    for artifact in expired {
      try? FileManager.default.removeItem(at: artifact.privateURI)
      records.removeValue(forKey: artifact.id)
    }
    return expired.map(\.id)
  }

  private static func writePrivateAtomically(
    _ data: Data,
    temporaryURL: URL,
    finalURL: URL
  ) throws {
    let descriptor = Darwin.open(
      temporaryURL.path,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      throw ArtifactStoreError.createFileFailed(errno)
    }

    var terminalError: ArtifactStoreError?
    data.withUnsafeBytes { rawBuffer in
      guard var pointer = rawBuffer.baseAddress else { return }
      var remaining = rawBuffer.count
      while remaining > 0 {
        let count = Darwin.write(descriptor, pointer, remaining)
        if count < 0 {
          terminalError = .writeFailed(errno)
          return
        }
        remaining -= count
        pointer = pointer.advanced(by: count)
      }
    }
    if terminalError == nil, Darwin.fsync(descriptor) != 0 {
      terminalError = .writeFailed(errno)
    }
    Darwin.close(descriptor)
    if let terminalError {
      Darwin.unlink(temporaryURL.path)
      throw terminalError
    }
    guard Darwin.rename(temporaryURL.path, finalURL.path) == 0 else {
      let renameError = errno
      Darwin.unlink(temporaryURL.path)
      throw ArtifactStoreError.commitFailed(renameError)
    }
  }

  private static func isSymbolicLink(_ url: URL) -> Bool {
    var information = stat()
    guard lstat(url.path, &information) == 0 else { return false }
    return (information.st_mode & S_IFMT) == S_IFLNK
  }

  private static func fileExtension(for mediaType: String) -> String {
    switch mediaType {
    case "image/png": "png"
    case "image/jpeg": "jpg"
    case "application/json": "json"
    case "text/markdown": "md"
    default: "dat"
    }
  }
}
