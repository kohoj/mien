import Darwin
import Foundation

public enum ManagedSubprocessError: Error, Equatable, Sendable {
  case pipeFailed(Int32)
  case launchFailed(Int32)
  case waitFailed(Int32)
}

public struct ManagedProcessExit: Equatable, Sendable {
  public let rawStatus: Int32

  public init(rawStatus: Int32) {
    self.rawStatus = rawStatus
  }

  public var exitCode: Int32 {
    if (rawStatus & 0x7F) == 0 { return (rawStatus >> 8) & 0xFF }
    return 128 + (rawStatus & 0x7F)
  }
}

/// Interactive subprocess ownership with a process group established before
/// `exec`. Closing or terminating this object always targets the descendant
/// tree, not just the immediate adapter process.
public final class ManagedSubprocess: @unchecked Sendable {
  public let processIdentifier: pid_t
  public let standardInput: FileHandle
  public let standardOutput: FileHandle
  public let standardError: FileHandle

  private let lock = NSLock()
  private var running = true
  private var terminationRequested = false

  private init(
    processIdentifier: pid_t,
    standardInput: FileHandle,
    standardOutput: FileHandle,
    standardError: FileHandle
  ) {
    self.processIdentifier = processIdentifier
    self.standardInput = standardInput
    self.standardOutput = standardOutput
    self.standardError = standardError
  }

  public static func launch(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    workingDirectory: URL? = nil
  ) throws -> ManagedSubprocess {
    var inputDescriptors: [Int32] = [0, 0]
    var outputDescriptors: [Int32] = [0, 0]
    var errorDescriptors: [Int32] = [0, 0]
    guard Darwin.pipe(&inputDescriptors) == 0 else {
      throw ManagedSubprocessError.pipeFailed(errno)
    }
    guard Darwin.pipe(&outputDescriptors) == 0 else {
      close(inputDescriptors[0])
      close(inputDescriptors[1])
      throw ManagedSubprocessError.pipeFailed(errno)
    }
    guard Darwin.pipe(&errorDescriptors) == 0 else {
      close(inputDescriptors[0])
      close(inputDescriptors[1])
      close(outputDescriptors[0])
      close(outputDescriptors[1])
      throw ManagedSubprocessError.pipeFailed(errno)
    }

    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    posix_spawn_file_actions_adddup2(&actions, inputDescriptors[0], STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&actions, outputDescriptors[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, errorDescriptors[1], STDERR_FILENO)
    for descriptor in [
      inputDescriptors[0], inputDescriptors[1],
      outputDescriptors[0], outputDescriptors[1],
      errorDescriptors[0], errorDescriptors[1],
    ] {
      posix_spawn_file_actions_addclose(&actions, descriptor)
    }
    if let workingDirectory {
      posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)
    }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attributes, 0)

    let argv = [executable.path] + arguments
    let environmentEntries =
      environment
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
    var processIdentifier: pid_t = 0
    let result = withCStringArray(argv) { argumentVector in
      withCStringArray(environmentEntries) { environmentVector in
        posix_spawn(
          &processIdentifier,
          executable.path,
          &actions,
          &attributes,
          argumentVector,
          environmentVector
        )
      }
    }

    close(inputDescriptors[0])
    close(outputDescriptors[1])
    close(errorDescriptors[1])
    guard result == 0 else {
      close(inputDescriptors[1])
      close(outputDescriptors[0])
      close(errorDescriptors[0])
      throw ManagedSubprocessError.launchFailed(result)
    }
    return ManagedSubprocess(
      processIdentifier: processIdentifier,
      standardInput: FileHandle(fileDescriptor: inputDescriptors[1], closeOnDealloc: true),
      standardOutput: FileHandle(fileDescriptor: outputDescriptors[0], closeOnDealloc: true),
      standardError: FileHandle(fileDescriptor: errorDescriptors[0], closeOnDealloc: true)
    )
  }

  public var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running
  }

  public func wait() throws -> ManagedProcessExit {
    var status: Int32 = 0
    while true {
      let result = Darwin.waitpid(processIdentifier, &status, 0)
      if result == processIdentifier {
        lock.lock()
        running = false
        lock.unlock()
        return ManagedProcessExit(rawStatus: status)
      }
      if result < 0, errno == EINTR { continue }
      throw ManagedSubprocessError.waitFailed(errno)
    }
  }

  public func terminate(grace: Duration = .seconds(2)) {
    lock.lock()
    guard running, !terminationRequested else {
      lock.unlock()
      return
    }
    terminationRequested = true
    lock.unlock()
    try? standardInput.close()
    _ = Darwin.kill(-processIdentifier, SIGTERM)
    Task.detached {
      try? await Task.sleep(for: grace)
      guard self.isRunning else { return }
      _ = Darwin.kill(-self.processIdentifier, SIGKILL)
    }
  }

  private static func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
  ) -> Result {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer {
      for pointer in pointers.dropLast() {
        free(pointer)
      }
    }
    return pointers.withUnsafeMutableBufferPointer { buffer in
      body(buffer.baseAddress!)
    }
  }
}
