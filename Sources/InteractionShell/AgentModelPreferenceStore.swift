import Foundation

/// Owns the one durable Pi model preference. Absence means “follow the Agent's
/// default”; the live Agent catalog remains the authority for valid IDs.
@MainActor
public final class AgentModelPreferenceStore {
  static let key = "mien.agent.pi-model-id.v1"

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var modelID: String? {
    guard let value = defaults.string(forKey: Self.key), !value.isEmpty else { return nil }
    return value
  }

  public func setModelID(_ modelID: String?) {
    if let modelID {
      precondition(!modelID.isEmpty, "Agent model ID must not be empty")
      defaults.set(modelID, forKey: Self.key)
    } else {
      defaults.removeObject(forKey: Self.key)
    }
  }
}
