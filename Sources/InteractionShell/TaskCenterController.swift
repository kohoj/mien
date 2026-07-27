import AppKit
import Foundation

@MainActor
final class TaskCenterController: NSObject {
  var onOpen: (() -> Void)?

  private var item: NSStatusItem?

  func show(status: String, completed: Bool) {
    let item = item ?? makeItem()
    self.item = item
    item.button?.image = NSImage(
      systemSymbolName: completed ? "checkmark.circle" : "circle.dotted",
      accessibilityDescription: completed ? "任务已完成" : "任务进行中"
    )
    item.button?.toolTip = status
    item.button?.setAccessibilityLabel(status)
  }

  func hide() {
    guard let item else { return }
    NSStatusBar.system.removeStatusItem(item)
    self.item = nil
  }

  private func makeItem() -> NSStatusItem {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.target = self
    item.button?.action = #selector(openTask)
    item.button?.sendAction(on: [.leftMouseUp])
    return item
  }

  @objc private func openTask() {
    onOpen?()
  }
}
