import Foundation
import MienContracts

public enum ACPConfigurationError: Error, Equatable, Sendable {
  case executableMustBeAbsolute
  case shellLauncherForbidden
  case invalidWorkingDirectory
  case invalidAdditionalDirectory
  case sensitiveLoggingForbidden
  case invalidRestartBudget
  case invalidExecutableDigest
}

public struct ACPProcessConfiguration: Equatable, Sendable {
  public let executableURL: URL
  public let arguments: [String]
  public let workingDirectoryURL: URL
  public let environment: [String: String]
  public let maximumRestartsPerMinute: Int
  public let expectedExecutableSHA256: String?

  public init(
    executableURL: URL,
    arguments: [String] = [],
    workingDirectoryURL: URL,
    environment: [String: String] = [:],
    maximumRestartsPerMinute: Int = 3,
    expectedExecutableSHA256: String? = nil
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.workingDirectoryURL = workingDirectoryURL
    self.environment = environment
    self.maximumRestartsPerMinute = maximumRestartsPerMinute
    self.expectedExecutableSHA256 = expectedExecutableSHA256
  }

  public func validate() throws {
    guard executableURL.isFileURL, executableURL.path.hasPrefix("/") else {
      throw ACPConfigurationError.executableMustBeAbsolute
    }
    let forbiddenLaunchers = ["sh", "bash", "zsh", "npx", "env"]
    guard !forbiddenLaunchers.contains(executableURL.lastPathComponent) else {
      throw ACPConfigurationError.shellLauncherForbidden
    }
    guard workingDirectoryURL.isFileURL,
      workingDirectoryURL.path.hasPrefix("/")
    else {
      throw ACPConfigurationError.invalidWorkingDirectory
    }
    guard environment["APP_SERVER_LOGS"] == nil else {
      throw ACPConfigurationError.sensitiveLoggingForbidden
    }
    guard (1...10).contains(maximumRestartsPerMinute) else {
      throw ACPConfigurationError.invalidRestartBudget
    }
    if let expectedExecutableSHA256 {
      guard expectedExecutableSHA256.count == 64,
        expectedExecutableSHA256.allSatisfy(\.isHexDigit)
      else {
        throw ACPConfigurationError.invalidExecutableDigest
      }
    }
  }

  public var sanitizedEnvironment: [String: String] {
    let allowed = Set([
      "PATH", "TMPDIR", "LANG", "LC_ALL", "CODEX_HOME", "NO_BROWSER",
      "CODEX_CONFIG", "CODEX_PATH", "MODEL_PROVIDER", "INITIAL_AGENT_MODE",
    ])
    return environment.filter { allowed.contains($0.key) }
  }
}

public enum ACPProcessState: Equatable, Sendable {
  case stopped
  case starting(attempt: Int)
  case handshaking
  case ready(protocolVersion: UInt16)
  case draining
  case backoff(until: Date)
  case failed(reason: String)
}

public enum ACPSupervisorError: Error, Equatable, Sendable {
  case invalidTransition
  case circuitOpen
  case unsupportedProtocol(UInt16)
}

/// Owns lifecycle truth independently from UI and agent output. Process IO is
/// attached behind this state machine so crashes cannot be mistaken for task
/// progress or success.
public actor ACPProcessSupervisor {
  public let configuration: ACPProcessConfiguration

  private var stateStorage: ACPProcessState = .stopped
  private var restartDates: [Date] = []

  public init(configuration: ACPProcessConfiguration) throws {
    try configuration.validate()
    self.configuration = configuration
  }

  public var state: ACPProcessState { stateStorage }

  public func beginStart(now: Date = Date()) throws {
    guard stateStorage == .stopped || isBackoffExpired(now: now) else {
      throw ACPSupervisorError.invalidTransition
    }
    restartDates = restartDates.filter { now.timeIntervalSince($0) < 60 }
    guard restartDates.count < configuration.maximumRestartsPerMinute else {
      stateStorage = .failed(reason: "restart circuit breaker opened")
      throw ACPSupervisorError.circuitOpen
    }
    restartDates.append(now)
    stateStorage = .starting(attempt: restartDates.count)
  }

  public func processDidLaunch() throws {
    guard case .starting = stateStorage else {
      throw ACPSupervisorError.invalidTransition
    }
    stateStorage = .handshaking
  }

  public func handshakeSucceeded(protocolVersion: UInt16) throws {
    guard stateStorage == .handshaking else {
      throw ACPSupervisorError.invalidTransition
    }
    guard protocolVersion == ACPProtocolV1.version else {
      stateStorage = .failed(reason: "unsupported ACP protocol \(protocolVersion)")
      throw ACPSupervisorError.unsupportedProtocol(protocolVersion)
    }
    stateStorage = .ready(protocolVersion: protocolVersion)
  }

  public func beginDrain() throws {
    guard case .ready = stateStorage else {
      throw ACPSupervisorError.invalidTransition
    }
    stateStorage = .draining
  }

  public func processDidStop() {
    stateStorage = .stopped
  }

  public func processDidCrash(now: Date = Date()) {
    restartDates = restartDates.filter { now.timeIntervalSince($0) < 60 }
    if restartDates.count >= configuration.maximumRestartsPerMinute {
      stateStorage = .failed(reason: "restart circuit breaker opened")
      return
    }
    let exponent = min(restartDates.count, 5)
    let seconds = pow(2.0, Double(exponent))
    stateStorage = .backoff(until: now.addingTimeInterval(seconds))
  }

  private func isBackoffExpired(now: Date) -> Bool {
    guard case .backoff(let until) = stateStorage else { return false }
    return now >= until
  }
}
