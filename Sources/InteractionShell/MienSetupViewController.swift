import AppKit
import PermissionKernel

/// Product copy is a projection of the same live readiness policy used to gate
/// invocation. Optional capabilities never become extra setup steps.
struct MienSetupPresentation: Equatable {
  let title: String
  let detail: String
  let action: String
  let code: String?
  let busy: Bool
  let chooseModel: Bool

  init(_ state: MienReadinessSnapshot) {
    code = if case .awaitingAuthorization(let code) = state.agent { code } else { nil }
    chooseModel = state.nextAction == .chooseModel
    switch state.nextAction {
    case .connectAgent:
      title = state.agent == .failed ? "重新连接你的账户" : "连接你的 ChatGPT 账户"
      detail = "Mien 通过 Codex 使用你的订阅。连接后，直接在当前窗口提问。"
      action = "连接 ChatGPT"
      busy = false
    case .requestPermission:
      title = "让 Mien 读懂当前窗口"
      detail = "在系统设置中允许辅助功能访问，以读取界面文字，并在你确认后插入草稿。"
      action = "打开系统设置"
      busy = false
    case .finish:
      title = "准备好了"
      detail = "回到正在看的窗口，按下快捷键，直接说出你想做的事。"
      action = "开始使用"
      busy = false
    case .wait:
      title = code != nil ? "在浏览器中完成连接" : "正在准备 Mien"
      detail =
        code != nil
        ? "在授权页面输入下方代码，完成后会自动继续。"
        : "正在确认账户和可用模型。这个窗口会自动更新。"
      action = code != nil ? "等待授权…" : "正在连接…"
      busy = true
    case .chooseModel:
      title = "选择一个可用模型"
      detail = "之前选择的模型已不可用。选择账户当前提供的模型后继续。"
      action = "请选择模型"
      busy = false
    case .refreshModels:
      title = "暂时无法读取模型"
      detail = "账户已连接。重新读取可用模型后，就能继续。"
      action = "重新读取"
      busy = false
    case .unavailable:
      title = "Mien 暂时无法启动"
      detail = "本地运行组件未通过检查。请重新安装完整的 Mien App。"
      action = "暂不可用"
      busy = false
    }
  }
}

@MainActor
final class MienSetupViewController: NSViewController, ReadinessContent {
  private let actions: ReadinessActions
  private let iconImage: NSImage
  private let titleLabel = ReadinessLayout.label("", size: 23, weight: .semibold)
  private let detailLabel = ReadinessLayout.label("", size: 13, secondary: true)
  private let codeLabel = ReadinessLayout.label("", size: 22, weight: .medium)
  private let modelPicker = AgentModelPicker()
  private let shortcut = ReadinessLayout.label("⌃  ⌥  Space", size: 19, weight: .medium)
  private let progress = NSProgressIndicator()
  private let primary = MienAccentButton()
  private var state: MienReadinessSnapshot?

  init(actions: ReadinessActions, iconImage: NSImage = NSApplication.shared.applicationIconImage) {
    self.actions = actions
    self.iconImage = iconImage
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let root = MienPaperView(frame: NSRect(origin: .zero, size: ReadinessMode.setup.contentSize))
    let icon = NSImageView(image: iconImage)
    icon.imageScaling = .scaleProportionallyDown
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.setAccessibilityElement(false)
    icon.wantsLayer = true
    icon.layer?.cornerRadius = 11
    icon.layer?.masksToBounds = true
    let name = ReadinessLayout.label("Mien", size: 22, weight: .medium)
    let tagline = ReadinessLayout.label("在当前窗口，直接提问。", size: 12, secondary: true)
    let brand = ReadinessLayout.stack([name, tagline], vertical: true, spacing: 3)
    let header = ReadinessLayout.stack([icon, brand], spacing: 14)
    codeLabel.font = .monospacedSystemFont(ofSize: 22, weight: .medium)
    codeLabel.isSelectable = true
    codeLabel.setAccessibilityLabel("浏览器授权代码")
    shortcut.font = .monospacedSystemFont(ofSize: 19, weight: .medium)
    shortcut.setAccessibilityLabel("Control Option Space，在当前窗口唤起 Mien")
    progress.style = .spinning
    progress.controlSize = .small
    progress.isDisplayedWhenStopped = false
    progress.setAccessibilityElement(false)
    let stateContent = ReadinessLayout.stack([codeLabel, modelPicker, shortcut], vertical: true)
    let content = ReadinessLayout.stack(
      [titleLabel, detailLabel, stateContent], vertical: true, spacing: 12)
    let privacy = ReadinessLayout.label("由你唤起，按需读取。写入前由你确认。", size: 11, secondary: true)
    let settings = NSButton(title: "设置…", target: self, action: #selector(openSettings))
    settings.bezelStyle = .accessoryBarAction
    settings.controlSize = .small
    settings.isBordered = false
    settings.contentTintColor = .secondaryLabelColor
    settings.font = .systemFont(ofSize: 12)
    primary.target = self
    primary.action = #selector(performPrimaryAction)
    primary.keyEquivalent = "\r"
    primary.translatesAutoresizingMaskIntoConstraints = false
    let footer = ReadinessLayout.stack([settings, NSView(), progress, primary], spacing: 10)
    modelPicker.onSelection = actions.selectModel
    for child in [header, content, privacy, footer] { root.addSubview(child) }
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
      header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
      icon.widthAnchor.constraint(equalToConstant: 52),
      icon.heightAnchor.constraint(equalToConstant: 52),
      content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 30),
      content.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
      titleLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
      detailLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
      stateContent.widthAnchor.constraint(equalTo: content.widthAnchor),
      modelPicker.widthAnchor.constraint(equalTo: stateContent.widthAnchor),
      privacy.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      privacy.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      privacy.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -20),
      footer.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
      primary.widthAnchor.constraint(greaterThanOrEqualToConstant: 128),
      primary.heightAnchor.constraint(equalToConstant: 32),
    ])
    view = root
  }

  func apply(_ snapshot: MienReadinessSnapshot) {
    loadViewIfNeeded()
    guard state != snapshot else { return }
    state = snapshot
    let presentation = MienSetupPresentation(snapshot)
    titleLabel.stringValue = presentation.title
    detailLabel.stringValue = presentation.detail
    codeLabel.stringValue = presentation.code ?? ""
    codeLabel.isHidden = presentation.code == nil
    modelPicker.isHidden = !presentation.chooseModel
    if presentation.chooseModel { modelPicker.apply(snapshot.models) }
    shortcut.isHidden = !snapshot.canUse
    primary.title = presentation.action
    primary.isEnabled =
      !presentation.busy && !presentation.chooseModel && snapshot.nextAction != .unavailable
    if presentation.busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    NSAccessibility.post(element: titleLabel, notification: .valueChanged)
  }

  func focus(_ permission: DesktopPermission?) {
    precondition(permission == nil, "Specific permissions are managed in Settings")
  }

  func showNavigationError(for permission: DesktopPermission) {
    detailLabel.stringValue = "未能打开系统设置。请在「隐私与安全性」中为 Mien 打开相应权限。"
    NSAccessibility.post(element: detailLabel, notification: .valueChanged)
  }

  @objc private func openSettings() { actions.showSettings() }

  @objc private func performPrimaryAction() {
    guard let state else { return }
    switch state.nextAction {
    case .connectAgent: actions.connect()
    case .refreshModels: actions.refreshModels()
    case .requestPermission(let permission): actions.request(permission, primary)
    case .finish: actions.finish()
    case .wait, .chooseModel, .unavailable: break
    }
  }
}
