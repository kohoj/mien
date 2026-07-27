import Foundation
import SubprocessKernel

public struct ProcessOutput: Equatable, Sendable {
  public let status: Int32
  public let standardOutput: Data
  public let standardError: Data

  public init(status: Int32, standardOutput: Data, standardError: Data) {
    self.status = status
    self.standardOutput = standardOutput
    self.standardError = standardError
  }
}

public enum ProcessRunnerError: Error, Equatable, Sendable {
  case timedOut
  case outputLimitExceeded
}

public protocol ProcessRunning: Sendable {
  func run(
    executable: URL,
    arguments: [String],
    environment: [String: String]
  ) async throws -> ProcessOutput
}

public struct FoundationProcessRunner: ProcessRunning {
  private let maximumRuntime: Duration
  private let maximumOutputBytes: Int
  private let terminationGrace: Duration

  public init(
    maximumRuntime: Duration = .seconds(30),
    maximumOutputBytes: Int = 8 * 1_024 * 1_024,
    terminationGrace: Duration = .seconds(2)
  ) {
    self.maximumRuntime = maximumRuntime
    self.maximumOutputBytes = max(64 * 1_024, maximumOutputBytes)
    self.terminationGrace = terminationGrace
  }

  public func run(
    executable: URL,
    arguments: [String],
    environment: [String: String]
  ) async throws -> ProcessOutput {
    let controller = ProcessCancellationController(terminationGrace: terminationGrace)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let process = try ManagedSubprocess.launch(
        executable: executable,
        arguments: arguments,
        environment: environment
      )
      controller.install(process)

      async let output = Self.drainWithoutBlockingExecutor(
        process.standardOutput,
        maximumBytes: maximumOutputBytes,
        controller: controller
      )
      async let error = Self.drainWithoutBlockingExecutor(
        process.standardError,
        maximumBytes: maximumOutputBytes,
        controller: controller
      )
      let timeoutTask = Task {
        try? await Task.sleep(for: maximumRuntime)
        guard !Task.isCancelled else { return }
        controller.cancel(reason: .timedOut)
      }

      let status = try await Self.waitWithoutBlockingExecutor(process)
      controller.clear(process)
      timeoutTask.cancel()
      let capturedOutput = try await output
      let capturedError = try await error
      switch controller.reason {
      case .cancelled?: throw CancellationError()
      case .timedOut?: throw ProcessRunnerError.timedOut
      case .outputLimitExceeded?: throw ProcessRunnerError.outputLimitExceeded
      case nil: break
      }
      return ProcessOutput(
        status: status.exitCode,
        standardOutput: capturedOutput,
        standardError: capturedError
      )
    } onCancel: {
      controller.cancel(reason: .cancelled)
    }
  }

  /// `waitpid` and pipe reads are blocking syscalls. Running them in
  /// `Task.detached` can exhaust Swift's cooperative executor on low-core
  /// machines, preventing cancellation and deadline tasks from running.
  private static func waitWithoutBlockingExecutor(
    _ process: ManagedSubprocess
  ) async throws -> ManagedProcessExit {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          continuation.resume(returning: try process.wait())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private static func drainWithoutBlockingExecutor(
    _ handle: FileHandle,
    maximumBytes: Int,
    controller: ProcessCancellationController
  ) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        do {
          continuation.resume(
            returning: try drain(
              handle,
              maximumBytes: maximumBytes,
              controller: controller
            ))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private static func drain(
    _ handle: FileHandle,
    maximumBytes: Int,
    controller: ProcessCancellationController
  ) throws -> Data {
    var result = Data()
    var totalRead = 0
    while true {
      guard let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty else { break }
      totalRead += chunk.count
      if result.count < maximumBytes {
        result.append(chunk.prefix(maximumBytes - result.count))
      }
      if totalRead > maximumBytes {
        controller.cancel(reason: .outputLimitExceeded)
      }
    }
    return result
  }
}

private final class ProcessCancellationController: @unchecked Sendable {
  enum Reason {
    case cancelled
    case timedOut
    case outputLimitExceeded
  }

  private let lock = NSLock()
  private let terminationGrace: Duration
  private var activeProcess: ManagedSubprocess?
  private var cancellationReason: Reason?

  init(terminationGrace: Duration) {
    self.terminationGrace = terminationGrace
  }

  var reason: Reason? {
    lock.lock()
    defer { lock.unlock() }
    return cancellationReason
  }

  func install(_ process: ManagedSubprocess) {
    lock.lock()
    activeProcess = process
    let shouldTerminate = cancellationReason != nil
    lock.unlock()
    if shouldTerminate { process.terminate(grace: terminationGrace) }
  }

  func clear(_ process: ManagedSubprocess) {
    lock.lock()
    if activeProcess === process { activeProcess = nil }
    lock.unlock()
  }

  func cancel(reason: Reason) {
    lock.lock()
    if cancellationReason == nil { cancellationReason = reason }
    let process = activeProcess
    lock.unlock()
    process?.terminate(grace: terminationGrace)
  }
}
