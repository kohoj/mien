import Foundation
import MienContracts
import PermissionKernel

public enum AgentConnectionReadiness: Equatable, Sendable {
  case checking
  case authenticationRequired
  case connecting
  case awaitingAuthorization(code: String)
  case connected(agentName: String)
  case unavailable
  case failed

  public var isConnected: Bool {
    if case .connected = self { return true }
    return false
  }
}

public enum AgentModelReadiness: Equatable, Sendable {
  case notLoaded(preferredModelID: String?)
  case loading(preferredModelID: String?)
  case available(catalog: AgentModelCatalog, preferredModelID: String?)
  case failed(preferredModelID: String?)

  public var preferredModelID: String? {
    switch self {
    case .notLoaded(let modelID), .loading(let modelID), .failed(let modelID):
      modelID
    case .available(_, let modelID):
      modelID
    }
  }

  public var isUsable: Bool {
    switch self {
    case .available(let catalog, let modelID):
      if let modelID { catalog.contains(modelID) } else { true }
    case .notLoaded, .loading, .failed:
      false
    }
  }

  func selecting(_ modelID: String?) -> AgentModelReadiness {
    switch self {
    case .notLoaded:
      .notLoaded(preferredModelID: modelID)
    case .loading:
      .loading(preferredModelID: modelID)
    case .available(let catalog, _):
      .available(catalog: catalog, preferredModelID: modelID)
    case .failed:
      .failed(preferredModelID: modelID)
    }
  }
}

public struct MienReadinessSnapshot: Equatable, Sendable {
  public let agent: AgentConnectionReadiness
  public let models: AgentModelReadiness
  public let permissions: DesktopPermissionReadiness

  public init(
    agent: AgentConnectionReadiness,
    models: AgentModelReadiness = .notLoaded(preferredModelID: nil),
    permissions: DesktopPermissionReadiness
  ) {
    self.agent = agent
    self.models = models
    self.permissions = permissions
  }

  public var canUse: Bool {
    agent.isConnected && models.isUsable
      && (permissions.accessibility == .authorized
        || permissions.screenRecording == .authorized)
  }

  public var isFullyReady: Bool {
    agent.isConnected && models.isUsable && permissions.isReady
  }

  public var nextAction: MienReadinessAction {
    switch agent {
    case .checking, .connecting, .awaitingAuthorization:
      .wait
    case .authenticationRequired, .failed:
      .connectAgent
    case .unavailable:
      .unavailable
    case .connected:
      if case .failed = models {
        .refreshModels
      } else if case .loading = models {
        .wait
      } else if case .notLoaded = models {
        .wait
      } else if !models.isUsable {
        .chooseModel
      } else if permissions.accessibility != .authorized,
        permissions.screenRecording != .authorized
      {
        .requestPermission(.accessibility)
      } else {
        .finish
      }
    }
  }

  var focusedPermission: DesktopPermission? {
    guard case .requestPermission(let permission) = nextAction else { return nil }
    return permission
  }
}

public enum MienReadinessAction: Equatable, Sendable {
  case wait
  case connectAgent
  case chooseModel
  case refreshModels
  case requestPermission(DesktopPermission)
  case finish
  case unavailable
}

struct MienOnboardingDecision {
  static func shouldPresent(
    hasSeenIntroduction: Bool,
    readiness: MienReadinessSnapshot
  ) -> Bool {
    guard hasSeenIntroduction else { return true }
    switch readiness.agent {
    case .checking, .connecting, .awaitingAuthorization:
      return false
    case .authenticationRequired, .unavailable, .failed:
      return true
    case .connected:
      return !readiness.canUse
    }
  }
}
