import AppKit
import Foundation

/// Owns Mien's discoverable native menu and application commands. Readiness and
/// task facts are projected here; the menu never invents capability or success.
@MainActor
final class TaskCenterController: NSObject, NSMenuDelegate {
  var onOpen: (() -> Void)?
  var onReadiness: (() -> Void)?
  var onQuit: (() -> Void)?
  var hasConversation: (() -> Bool)?

  private var item: NSStatusItem?
  private var shortcutDescription = ""
  private var ready = false
  private var taskStatus: String?
  private var taskFinished = false
  private var notice: NSPopover?

  func install(shortcutDescription: String) {
    self.shortcutDescription = shortcutDescription
    if item == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      item.behavior = [.terminationOnRemoval]
      let menu = NSMenu()
      menu.delegate = self
      menu.autoenablesItems = false
      item.menu = menu
      self.item = item
    }
    installApplicationMenu()
    updateIcon()
  }

  func setReady(_ ready: Bool) {
    guard self.ready != ready else { return }
    self.ready = ready
    updateIcon()
  }

  func show(status: String, completed: Bool) {
    taskStatus = status
    taskFinished = completed
    updateIcon()
  }

  func hide() {
    taskStatus = nil
    taskFinished = false
    updateIcon()
  }

  func remove() {
    notice?.close()
    notice = nil
    guard let item else { return }
    NSStatusBar.system.removeStatusItem(item)
    self.item = nil
  }

  private func updateIcon() {
    guard let button = item?.button else { return }
    button.image = MienMark.image(attention: taskStatus != nil)
    let status = taskStatus ?? (ready ? "Mien · \(shortcutDescription) 提问" : "Mien · 需要完成设置")
    button.toolTip = status
    button.setAccessibilityLabel(status)
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    for item in makeMenuItems() { menu.addItem(item) }
  }

  func makeMenuItems() -> [NSMenuItem] {
    let hasSession = hasConversation?() ?? (taskStatus != nil)
    let title =
      hasSession
      ? (taskStatus != nil && !taskFinished ? "返回当前任务" : "继续对话")
      : (ready ? "对当前窗口提问" : "完成设置…")
    let open = command(
      title + (!hasSession && ready ? "　\(shortcutDescription)" : ""),
      action: #selector(openFromMenu))
    var items = [open]
    if let taskStatus {
      let status = NSMenuItem(title: taskStatus, action: nil, keyEquivalent: "")
      status.isEnabled = false
      items.append(status)
    }
    items += [
      .separator(), command("设置…", action: #selector(openReadiness), key: ","),
      .separator(), command("退出 Mien", action: #selector(quitFromMenu), key: "q"),
    ]
    return items
  }

  /// An invocation with no valid target has no conversation to attach an error
  /// to. Explain the typed identity failure at the app's stable menu-bar entry.
  func showInvocationFailure(_ message: String) {
    guard let button = item?.button else { return }
    notice?.close()
    let title = ReadinessLayout.label("未能打开当前窗口", size: 13, weight: .semibold)
    let detail = ReadinessLayout.label(message, size: 12, secondary: true)
    let stack = ReadinessLayout.stack([title, detail], vertical: true, spacing: 6)
    let controller = NSViewController()
    controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 92))
    controller.view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 16),
      detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    let popover = NSPopover()
    popover.contentViewController = controller
    popover.contentSize = controller.view.frame.size
    popover.behavior = .transient
    popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    notice = popover
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    NSAccessibility.post(
      element: detail, notification: .announcementRequested,
      userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
  }

  private func command(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = self
    return item
  }

  private func installApplicationMenu() {
    let main = NSMenu()
    let app = NSMenuItem(title: "Mien", action: nil, keyEquivalent: "")
    app.submenu = NSMenu(title: "Mien")
    app.submenu?.addItem(command("Mien 设置…", action: #selector(openReadiness), key: ","))
    app.submenu?.addItem(.separator())
    app.submenu?.addItem(command("退出 Mien", action: #selector(quitFromMenu), key: "q"))
    main.addItem(app)
    let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
    edit.submenu = NSMenu(title: "编辑")
    for (title, action, key) in [
      ("撤销", "undo:", "z"), ("重做", "redo:", "Z"),
      ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"),
      ("全选", "selectAll:", "a"),
    ] {
      edit.submenu?.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
    }
    main.addItem(edit)
    let window = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
    let windowMenu = NSMenu(title: "窗口")
    windowMenu.addItem(
      NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
    window.submenu = windowMenu
    main.addItem(window)
    NSApp.mainMenu = main
    NSApp.windowsMenu = windowMenu
  }

  @objc private func openFromMenu() { onOpen?() }
  @objc private func openReadiness() { onReadiness?() }
  @objc private func quitFromMenu() { onQuit?() }
}
