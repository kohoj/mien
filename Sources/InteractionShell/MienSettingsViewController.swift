import AppKit
import PermissionKernel

@MainActor
final class MienSettingsViewController: NSViewController, ReadinessContent {
  private let actions: ReadinessActions
  private let connection = ReadinessLayout.label("", secondary: true)
  private let connectButton = NSButton()
  private let modelPicker = AgentModelPicker()
  private let modelHelp = ReadinessLayout.label("用于下一次提问。正在进行的任务不受影响。", size: 11, secondary: true)
  private let accessibilityRow: PermissionSettingRow
  private let screenRow: PermissionSettingRow
  private var state: MienReadinessSnapshot?

  init(actions: ReadinessActions) {
    self.actions = actions
    accessibilityRow = PermissionSettingRow(permission: .accessibility, onRequest: actions.request)
    screenRow = PermissionSettingRow(permission: .screenRecording, onRequest: actions.request)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let root = MienPaperView(frame: NSRect(origin: .zero, size: ReadinessMode.settings.contentSize))
    let accountHeading = ReadinessLayout.label("账户与模型", size: 12, weight: .semibold)
    let account = ReadinessLayout.label("ChatGPT", weight: .medium)
    connection.isSelectable = true
    connectButton.bezelStyle = .rounded
    connectButton.controlSize = .small
    connectButton.target = self
    connectButton.action = #selector(connect)
    let connectionRow = ReadinessLayout.stack([account, NSView(), connection, connectButton])
    modelPicker.onSelection = actions.selectModel
    modelPicker.translatesAutoresizingMaskIntoConstraints = false
    let modelRow = ReadinessLayout.stack([ReadinessLayout.label("模型"), NSView(), modelPicker])
    modelPicker.widthAnchor.constraint(equalToConstant: 264).isActive = true
    let permissionHeading = ReadinessLayout.label("访问权限", size: 12, weight: .semibold)
    let permissionLine = ReadinessLayout.separator()
    let shortcutLabel = ReadinessLayout.label("唤起 Mien", weight: .medium)
    let shortcutValue = ReadinessLayout.label("⌃  ⌥  Space", size: 13, weight: .medium)
    shortcutValue.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
    shortcutValue.setAccessibilityLabel("快捷键 Control Option Space")
    let help = NSButton(title: "使用说明…", target: self, action: #selector(showSetup))
    help.bezelStyle = .accessoryBarAction
    help.controlSize = .small
    help.isBordered = false
    help.contentTintColor = .secondaryLabelColor
    help.font = .systemFont(ofSize: 12)
    let shortcutRow = ReadinessLayout.stack(
      [shortcutLabel, NSView(), shortcutValue, help], spacing: 12)
    let privacy = ReadinessLayout.label(
      "由你唤起，按需读取。草稿只会在你确认后写入，Mien 不会发送消息。", size: 11, secondary: true)
    let views = [
      accountHeading, connectionRow, modelRow, modelHelp, permissionHeading,
      accessibilityRow, permissionLine, screenRow, shortcutRow, privacy,
    ]
    let stack = ReadinessLayout.stack(views, vertical: true, spacing: 10)
    stack.setCustomSpacing(20, after: modelHelp)
    stack.setCustomSpacing(20, after: screenRow)
    stack.setCustomSpacing(20, after: shortcutRow)
    root.addSubview(stack)
    NSLayoutConstraint.activate(
      [
        stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
        stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
        stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
        stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
        accessibilityRow.heightAnchor.constraint(equalToConstant: 48),
        screenRow.heightAnchor.constraint(equalToConstant: 48),
      ] + views.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
    view = root
  }

  func apply(_ snapshot: MienReadinessSnapshot) {
    loadViewIfNeeded()
    guard state != snapshot else { return }
    state = snapshot
    modelPicker.apply(snapshot.models)
    accessibilityRow.apply(snapshot.permissions.accessibility)
    screenRow.apply(snapshot.permissions.screenRecording)
    connectButton.isHidden = true
    switch snapshot.agent {
    case .connected:
      connection.stringValue = "已连接"
      if case .failed = snapshot.models {
        connection.stringValue = "模型列表不可用"
        connectButton.title = "重新读取"
        connectButton.isHidden = false
      }
    case .checking, .connecting:
      connection.stringValue = "正在连接…"
    case .awaitingAuthorization(let code):
      connection.stringValue = "浏览器代码：\(code)"
    case .authenticationRequired, .failed:
      connection.stringValue = snapshot.agent == .failed ? "连接中断" : "尚未连接"
      connectButton.title = "连接…"
      connectButton.isHidden = false
    case .unavailable:
      connection.stringValue = "本地组件不可用"
    }
    if case .available = snapshot.models {
      modelPicker.isEnabled = snapshot.agent.isConnected
    } else {
      modelPicker.isEnabled = false
    }
  }

  func focus(_ permission: DesktopPermission?) {
    guard let permission else { return }
    let row = permission == .accessibility ? accessibilityRow : screenRow
    view.window?.makeFirstResponder(row.button)
  }

  func showNavigationError(for permission: DesktopPermission) {
    (permission == .accessibility ? accessibilityRow : screenRow).showNavigationError()
  }

  @objc private func connect() {
    if let state, case .failed = state.models, state.agent.isConnected {
      actions.refreshModels()
    } else {
      actions.connect()
    }
  }

  @objc private func showSetup() { actions.showSetup() }
}

@MainActor
private final class PermissionSettingRow: NSView {
  let button = NSButton()
  private let permission: DesktopPermission
  private let onRequest: (DesktopPermission, NSView) -> Void
  private let status = ReadinessLayout.label("", size: 11, secondary: true)
  private var permissionStatus: DesktopPermissionStatus?

  init(permission: DesktopPermission, onRequest: @escaping (DesktopPermission, NSView) -> Void) {
    self.permission = permission
    self.onRequest = onRequest
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    let title = ReadinessLayout.label(
      permission == .accessibility ? "界面文字与草稿" : "屏幕画面（可选）", weight: .medium)
    let detail = ReadinessLayout.label(
      permission == .accessibility
        ? "读取文字，并在确认后插入草稿" : "理解图片和无法直接读取的界面", size: 11, secondary: true)
    let copy = ReadinessLayout.stack([title, detail], vertical: true, spacing: 3)
    button.bezelStyle = .rounded
    button.controlSize = .small
    button.target = self
    button.action = #selector(open)
    button.setAccessibilityLabel(permission == .accessibility ? "管理辅助功能访问" : "管理屏幕画面访问")
    let row = ReadinessLayout.stack([copy, NSView(), status, button], spacing: 10)
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func apply(_ permissionStatus: DesktopPermissionStatus) {
    guard self.permissionStatus != permissionStatus else { return }
    self.permissionStatus = permissionStatus
    let allowed = permissionStatus == .authorized
    status.stringValue = allowed ? "已允许" : "未允许"
    status.textColor = .secondaryLabelColor
    button.title = allowed ? "管理…" : "打开设置…"
  }

  func showNavigationError() {
    status.stringValue = "打开失败"
    status.textColor = .systemRed
    NSAccessibility.post(element: status, notification: .valueChanged)
  }

  @objc private func open() { onRequest(permission, button) }
}
