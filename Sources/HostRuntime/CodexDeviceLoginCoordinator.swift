import Foundation
import SubprocessKernel

public struct CodexDeviceAuthorization: Equatable, Sendable {
  public let verificationURL: URL
  public let userCode: String
  public let expiresAt: Date

  public init(verificationURL: URL, userCode: String, expiresAt: Date) {
    self.verificationURL = verificationURL
    self.userCode = userCode
    self.expiresAt = expiresAt
  }
}

public enum CodexDeviceLoginError: Error, Equatable, Sendable {
  case invalidConfiguration
  case authorizationDetailsUnavailable
  case loginFailed(exitCode: Int32)
  case invalidCredential
  case timedOut
}

public struct CodexDeviceLoginConfiguration: Equatable, Sendable {
  public let executableURL: URL
  public let codexHomeURL: URL
  public let workingDirectoryURL: URL
  public let environment: [String: String]
  public let deadline: TimeInterval

  public init(
    executableURL: URL,
    codexHomeURL: URL,
    workingDirectoryURL: URL,
    environment: [String: String],
    deadline: TimeInterval = 16 * 60
  ) throws {
    guard executableURL.isFileURL, executableURL.path.hasPrefix("/"),
      codexHomeURL.isFileURL, codexHomeURL.path.hasPrefix("/"),
      workingDirectoryURL.isFileURL, workingDirectoryURL.path.hasPrefix("/"),
      deadline >= 30, deadline <= 20 * 60
    else {
      throw CodexDeviceLoginError.invalidConfiguration
    }
    self.executableURL = executableURL
    self.codexHomeURL = codexHomeURL
    self.workingDirectoryURL = workingDirectoryURL
    self.environment = environment
    self.deadline = deadline
  }
}

public actor CodexDeviceLoginCoordinator {
  private let configuration: CodexDeviceLoginConfiguration
  private var process: ManagedSubprocess?

  public init(configuration: CodexDeviceLoginConfiguration) {
    self.configuration = configuration
  }

  public func authenticate(
    onAuthorization: @escaping @Sendable (CodexDeviceAuthorization) async -> Void
  ) async throws {
    guard process == nil else { throw CodexDeviceLoginError.invalidConfiguration }
    try FileManager.default.createDirectory(
      at: configuration.codexHomeURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: configuration.codexHomeURL.path
    )

    var environment = configuration.environment
    environment["CODEX_HOME"] = configuration.codexHomeURL.path
    environment["NO_BROWSER"] = "1"
    let launched = try ManagedSubprocess.launch(
      executable: configuration.executableURL,
      arguments: ["login", "--device-auth"],
      environment: environment,
      workingDirectory: configuration.workingDirectoryURL
    )
    process = launched
    let accumulator = DeviceLoginOutputAccumulator(onAuthorization: onAuthorization)
    let deadline = configuration.deadline

    do {
      let exit = try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: ManagedProcessExit?.self) { group in
          group.addTask {
            await Self.consume(launched.standardOutput, accumulator: accumulator)
            return nil
          }
          group.addTask {
            await Self.consume(launched.standardError, accumulator: accumulator)
            return nil
          }
          group.addTask {
            try await Task.detached(priority: .utility) { try launched.wait() }.value
          }
          group.addTask {
            try await Task.sleep(for: .seconds(deadline))
            launched.terminate()
            throw CodexDeviceLoginError.timedOut
          }
          while let candidate = try await group.next() {
            if let exit = candidate {
              group.cancelAll()
              return exit
            }
          }
          throw CodexDeviceLoginError.loginFailed(exitCode: -1)
        }
      } onCancel: {
        launched.terminate()
      }
      process = nil
      guard exit.exitCode == 0 else {
        throw CodexDeviceLoginError.loginFailed(exitCode: exit.exitCode)
      }
      guard await accumulator.didPublishAuthorization else {
        throw CodexDeviceLoginError.authorizationDetailsUnavailable
      }
      guard try CodexCredentialBootstrap().validateCredentialHome(configuration.codexHomeURL) else {
        throw CodexDeviceLoginError.invalidCredential
      }
    } catch {
      launched.terminate()
      process = nil
      throw error
    }
  }

  public func cancel() {
    process?.terminate()
    process = nil
  }

  private nonisolated static func consume(
    _ handle: FileHandle,
    accumulator: DeviceLoginOutputAccumulator
  ) async {
    while !Task.isCancelled {
      do {
        guard let data = try handle.read(upToCount: 4_096), !data.isEmpty else { return }
        await accumulator.ingest(data)
      } catch {
        return
      }
    }
  }
}

actor DeviceLoginOutputAccumulator {
  private let maximumBytes = 64 * 1_024
  private let onAuthorization: @Sendable (CodexDeviceAuthorization) async -> Void
  private var buffer = Data()
  private(set) var didPublishAuthorization = false

  init(onAuthorization: @escaping @Sendable (CodexDeviceAuthorization) async -> Void) {
    self.onAuthorization = onAuthorization
  }

  func ingest(_ data: Data, now: Date = Date()) async {
    guard !didPublishAuthorization else { return }
    let remaining = maximumBytes - buffer.count
    guard remaining > 0 else { return }
    buffer.append(data.prefix(remaining))
    guard let text = String(data: buffer, encoding: .utf8),
      let authorization = DeviceLoginOutputParser.parse(text, now: now)
    else { return }
    didPublishAuthorization = true
    await onAuthorization(authorization)
  }
}

enum DeviceLoginOutputParser {
  static func parse(_ raw: String, now: Date) -> CodexDeviceAuthorization? {
    let text = raw.replacingOccurrences(
      of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
      with: "",
      options: .regularExpression
    )
    guard
      let urlRange = text.range(
        of: #"https://auth\.openai\.com/codex/device"#,
        options: .regularExpression
      ),
      let codeRange = text.range(
        of: #"\b[A-Z0-9]{4}-[A-Z0-9]{5}\b"#,
        options: .regularExpression
      ), let url = URL(string: String(text[urlRange]))
    else { return nil }
    return CodexDeviceAuthorization(
      verificationURL: url,
      userCode: String(text[codeRange]),
      expiresAt: now.addingTimeInterval(15 * 60)
    )
  }
}
