import AppKit
import MienContracts
import PermissionKernel

public enum ReadinessPreviewState: String, CaseIterable, Sendable {
  case onboarding
  case settings
  case connect = "setup-connect"
  case permission = "setup-permission"
  case authorization = "setup-authorization"
  case catalogFailure = "setup-model-error"
}

@MainActor
public enum ReadinessPreviewRenderer {
  public static func png(
    state: ReadinessPreviewState = .onboarding,
    appearance: NSAppearance.Name = .aqua
  ) throws -> Data {
    let iconURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Resources/AppIcon/mien-1024.png")
    guard let icon = NSImage(contentsOf: iconURL) else { throw CocoaError(.fileReadNoSuchFile) }
    let mode: ReadinessMode = state == .settings ? .settings : .setup
    let content: any ReadinessContent =
      mode == .settings
      ? MienSettingsViewController(actions: .preview)
      : MienSetupViewController(actions: .preview, iconImage: icon)
    let catalog = AgentModelCatalog(
      currentModelID: "preview-default",
      options: [
        AgentModelOption(id: "preview-default", name: "账户默认模型"),
        AgentModelOption(id: "preview-alternative", name: "另一可用模型"),
      ])
    let agent: AgentConnectionReadiness =
      switch state {
      case .connect: .authenticationRequired
      case .authorization: .awaitingAuthorization(code: "ABCD-EFGH")
      default: .connected(agentName: "已连接")
      }
    let models: AgentModelReadiness =
      state == .catalogFailure
      ? .failed(preferredModelID: nil) : .available(catalog: catalog, preferredModelID: nil)
    let permissions = DesktopPermissionReadiness(
      accessibility: state == .settings || state == .onboarding
        ? .authorized : .deniedOrNotRequested,
      screenRecording: .deniedOrNotRequested)
    content.controller.preferredContentSize = mode.contentSize
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: mode.contentSize),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.backgroundColor = MienAppearance.paper
    window.contentViewController = content.controller
    window.setContentSize(mode.contentSize)
    content.apply(MienReadinessSnapshot(agent: agent, models: models, permissions: permissions))
    let view = content.controller.view
    view.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw CocoaError(.fileWriteUnknown)
    }
    view.cacheDisplay(in: view.bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    return data
  }
}
