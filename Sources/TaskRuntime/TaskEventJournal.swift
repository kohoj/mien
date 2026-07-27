import Darwin
import Foundation
import MienContracts

public enum TaskEventJournalError: Error, Equatable, Sendable {
  case pathMustBeAbsolute
  case symbolicLinkRejected
  case createFailed(Int32)
  case journalTooLarge
  case invalidRecord
  case rotationFailed(Int32)
  case quarantineFailed(Int32)
}

public enum JournalTailRecovery: Equatable, Sendable {
  case intact
  case completedMissingNewline
  case quarantined(byteCount: Int)
}

public protocol TaskEventJournaling: Sendable {
  func append(_ events: [TaskEvent]) async throws
  func replay() async throws -> [TaskEvent]
}

/// Segmented append-only task truth. Private context bytes never enter this
/// journal; only immutable IDs, digests, states, and reasons are persisted.
/// Closed segments are immutable. Only the active tail can be repaired.
public actor JSONLTaskEventJournal: TaskEventJournaling {
  private let fileURL: URL
  private let segmentMaximumBytes: Int
  private let encoder: JSONEncoder

  /// `maximumBytes` is the per-segment bound, not a lifetime cap. The journal
  /// rotates before crossing it, so long-running installations do not stop at
  /// an arbitrary cumulative byte count.
  public init(
    fileURL: URL,
    maximumBytes: Int = 8 * 1_024 * 1_024
  ) throws {
    guard fileURL.isFileURL, fileURL.path.hasPrefix("/") else {
      throw TaskEventJournalError.pathMustBeAbsolute
    }
    let standardized = fileURL.standardizedFileURL
    try Self.rejectSymbolicLink(standardized)
    try FileManager.default.createDirectory(
      at: standardized.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try Self.createActiveFileIfNeeded(at: standardized)
    self.fileURL = standardized
    self.segmentMaximumBytes = max(512, maximumBytes)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    self.encoder = encoder
  }

  public func append(_ events: [TaskEvent]) async throws {
    guard !events.isEmpty else { return }
    var pending = Data()
    var activeSize = try Self.regularFileSize(at: fileURL)
    for event in events {
      var record = try encoder.encode(event)
      record.append(0x0A)
      guard record.count <= segmentMaximumBytes else {
        throw TaskEventJournalError.journalTooLarge
      }
      if activeSize + pending.count + record.count > segmentMaximumBytes {
        if !pending.isEmpty {
          try Self.appendPrivate(pending, to: fileURL)
          activeSize += pending.count
          pending.removeAll(keepingCapacity: true)
        }
        if activeSize > 0 {
          try rotateActiveSegment()
          activeSize = 0
        }
      }
      pending.append(record)
    }
    if !pending.isEmpty {
      try Self.appendPrivate(pending, to: fileURL)
    }
  }

  public func replay() async throws -> [TaskEvent] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var events: [TaskEvent] = []
    for url in try orderedJournalURLs() {
      try Self.rejectSymbolicLink(url)
      let size = try Self.regularFileSize(at: url)
      guard size <= segmentMaximumBytes else {
        throw TaskEventJournalError.journalTooLarge
      }
      let data = try Data(contentsOf: url, options: [.mappedIfSafe])
      if url != fileURL, !data.isEmpty, data.last != 0x0A {
        throw TaskEventJournalError.invalidRecord
      }
      for line in data.split(separator: 0x0A) where !line.isEmpty {
        guard let event = try? decoder.decode(TaskEvent.self, from: Data(line)) else {
          throw TaskEventJournalError.invalidRecord
        }
        events.append(event)
      }
    }
    return events
  }

  /// Repairs only a torn final write in the active file. Mid-file corruption
  /// and corruption in immutable segments still fail closed.
  public func repairTrailingRecord() throws -> JournalTailRecovery {
    try Self.rejectSymbolicLink(fileURL)
    let size = try Self.regularFileSize(at: fileURL)
    guard size <= segmentMaximumBytes else { throw TaskEventJournalError.journalTooLarge }
    let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    guard !data.isEmpty, data.last != 0x0A else { return .intact }
    let tailStart = data.lastIndex(of: 0x0A).map { data.index(after: $0) } ?? data.startIndex
    let tail = Data(data[tailStart...])
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if (try? decoder.decode(TaskEvent.self, from: tail)) != nil {
      try Self.appendPrivate(Data([0x0A]), to: fileURL)
      return .completedMissingNewline
    }

    let quarantineURL = fileURL.deletingPathExtension()
      .appendingPathExtension("recovered-tail.\(UUID().uuidString).bin")
    try Self.writePrivate(tail, to: quarantineURL)
    let descriptor = Darwin.open(fileURL.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw TaskEventJournalError.createFailed(errno) }
    let truncateResult = Darwin.ftruncate(descriptor, off_t(tailStart))
    let syncResult = truncateResult == 0 ? Darwin.fsync(descriptor) : -1
    let failure = truncateResult == 0 && syncResult == 0 ? nil : errno
    Darwin.close(descriptor)
    if let failure { throw TaskEventJournalError.quarantineFailed(failure) }
    return .quarantined(byteCount: tail.count)
  }

  private func rotateActiveSegment() throws {
    let segmentURL = try nextSegmentURL()
    guard
      Darwin.renamex_np(
        fileURL.path,
        segmentURL.path,
        UInt32(RENAME_EXCL)
      ) == 0
    else {
      throw TaskEventJournalError.rotationFailed(errno)
    }
    do {
      try Self.createActiveFileIfNeeded(at: fileURL)
      try Self.synchronizeDirectory(fileURL.deletingLastPathComponent())
    } catch {
      throw error
    }
  }

  private func orderedJournalURLs() throws -> [URL] {
    try segmentURLs() + [fileURL]
  }

  private func nextSegmentURL() throws -> URL {
    let existing = try segmentURLs()
    let next = (existing.compactMap(segmentIndex).max() ?? 0) + 1
    return segmentURL(index: next)
  }

  private func segmentURLs() throws -> [URL] {
    let directory = fileURL.deletingLastPathComponent()
    return try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    .filter { segmentIndex($0) != nil }
    .sorted { segmentIndex($0)! < segmentIndex($1)! }
  }

  private func segmentURL(index: Int) -> URL {
    let stem = fileURL.deletingPathExtension().lastPathComponent
    let ext = fileURL.pathExtension.isEmpty ? "jsonl" : fileURL.pathExtension
    return fileURL.deletingLastPathComponent()
      .appendingPathComponent(String(format: "%@.%08d.%@", stem, index, ext))
  }

  private func segmentIndex(_ url: URL) -> Int? {
    let stem = fileURL.deletingPathExtension().lastPathComponent
    let ext = fileURL.pathExtension.isEmpty ? "jsonl" : fileURL.pathExtension
    let name = url.lastPathComponent
    let prefix = "\(stem)."
    let suffix = ".\(ext)"
    guard name != fileURL.lastPathComponent,
      name.count == prefix.count + 8 + suffix.count,
      name.hasPrefix(prefix), name.hasSuffix(suffix)
    else { return nil }
    let start = name.index(name.startIndex, offsetBy: prefix.count)
    let end = name.index(name.endIndex, offsetBy: -suffix.count)
    let digits = name[start..<end]
    guard digits.count == 8, digits.allSatisfy(\.isNumber) else { return nil }
    return Int(digits)
  }

  private static func createActiveFileIfNeeded(at url: URL) throws {
    let descriptor = Darwin.open(
      url.path,
      O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else { throw TaskEventJournalError.createFailed(errno) }
    Darwin.close(descriptor)
  }

  private static func appendPrivate(_ data: Data, to url: URL) throws {
    try rejectSymbolicLink(url)
    let descriptor = Darwin.open(
      url.path,
      O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else { throw TaskEventJournalError.createFailed(errno) }
    var failure: Int32?
    data.withUnsafeBytes { buffer in
      guard var pointer = buffer.baseAddress else { return }
      var remaining = buffer.count
      while remaining > 0 {
        let count = Darwin.write(descriptor, pointer, remaining)
        if count < 0 {
          if errno == EINTR { continue }
          failure = errno
          return
        }
        pointer = pointer.advanced(by: count)
        remaining -= count
      }
    }
    if failure == nil, Darwin.fsync(descriptor) != 0 { failure = errno }
    Darwin.close(descriptor)
    if let failure { throw TaskEventJournalError.createFailed(failure) }
  }

  private static func regularFileSize(at url: URL) throws -> Int {
    var information = stat()
    guard lstat(url.path, &information) == 0 else {
      throw TaskEventJournalError.createFailed(errno)
    }
    guard (information.st_mode & S_IFMT) == S_IFREG else {
      throw TaskEventJournalError.symbolicLinkRejected
    }
    return Int(information.st_size)
  }

  private static func rejectSymbolicLink(_ url: URL) throws {
    var information = stat()
    guard lstat(url.path, &information) == 0 else { return }
    guard (information.st_mode & S_IFMT) != S_IFLNK else {
      throw TaskEventJournalError.symbolicLinkRejected
    }
  }

  private static func synchronizeDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw TaskEventJournalError.createFailed(errno) }
    let result = Darwin.fsync(descriptor)
    let failure = result == 0 ? nil : errno
    Darwin.close(descriptor)
    if let failure { throw TaskEventJournalError.createFailed(failure) }
  }

  private static func writePrivate(_ data: Data, to url: URL) throws {
    let descriptor = Darwin.open(
      url.path,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else { throw TaskEventJournalError.quarantineFailed(errno) }
    var failure: Int32?
    data.withUnsafeBytes { buffer in
      guard var pointer = buffer.baseAddress else { return }
      var remaining = buffer.count
      while remaining > 0 {
        let count = Darwin.write(descriptor, pointer, remaining)
        if count < 0 {
          if errno == EINTR { continue }
          failure = errno
          return
        }
        pointer = pointer.advanced(by: count)
        remaining -= count
      }
    }
    if failure == nil, Darwin.fsync(descriptor) != 0 { failure = errno }
    Darwin.close(descriptor)
    if let failure {
      Darwin.unlink(url.path)
      throw TaskEventJournalError.quarantineFailed(failure)
    }
  }
}
