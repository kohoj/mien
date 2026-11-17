import AppKit
import MienContracts

/// Owns the complete AppKit contract for selecting the model used by the next
/// Agent task. The live catalog and durable preference remain outside the
/// control; this view owns only native menu projection and selection events.
@MainActor
final class AgentModelPicker: NSPopUpButton {
  var onSelection: ((String?) -> Void)?

  private var renderedReadiness: AgentModelReadiness?

  override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
    super.init(frame: buttonFrame, pullsDown: flag)
    target = self
    action = #selector(selectionChanged)
    setAccessibilityLabel("Codex 模型")
    setAccessibilityHelp("应用于下一次任务；正在进行的任务不会切换")
  }

  convenience init() {
    self.init(frame: .zero, pullsDown: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  /// Re-projects only when the source of truth changes. Readiness refreshes run
  /// while System Settings is open; rebuilding an unchanged NSMenu on every
  /// timer tick would invalidate a menu while the user is choosing an item.
  func apply(_ readiness: AgentModelReadiness) {
    guard renderedReadiness != readiness else { return }
    renderedReadiness = readiness
    removeAllItems()

    switch readiness {
    case .notLoaded, .loading:
      addItem(withTitle: "正在读取模型…")
      isEnabled = false

    case .failed:
      addItem(withTitle: "模型列表读取失败")
      isEnabled = false

    case .available(let catalog, let preferredModelID):
      var unavailable: NSMenuItem?
      if let preferredModelID, !catalog.contains(preferredModelID) {
        unavailable = appendItem(title: "所选模型不可用", modelID: nil)
        unavailable?.isEnabled = false
        appendSeparator()
      }

      let defaultName = catalog.option(for: catalog.currentModelID)?.name ?? catalog.currentModelID
      let defaultItem = appendItem(
        title: "默认 · \(defaultName)",
        modelID: nil,
        toolTip: "跟随 Codex 默认模型"
      )
      appendSeparator()

      for option in catalog.options {
        _ = appendItem(
          title: option.name,
          modelID: option.id,
          toolTip: option.description
        )
      }

      if let preferredModelID,
        let selected = itemArray.first(where: {
          ($0.representedObject as? String) == preferredModelID
        })
      {
        select(selected)
      } else if preferredModelID == nil {
        select(defaultItem)
      } else if let unavailable {
        select(unavailable)
      }
      isEnabled = true
    }

    updateAccessibilityValue()
  }

  var selectedModelID: String? {
    selectedItem?.representedObject as? String
  }

  private func appendItem(
    title: String,
    modelID: String?,
    toolTip: String? = nil
  ) -> NSMenuItem {
    // NSPopUpButton must create selectable items itself. Its cell installs the
    // native menu target-action that updates selection before forwarding the
    // control action; inserting an actionless NSMenuItem bypasses that path.
    addItem(withTitle: title)
    guard let item = lastItem else {
      preconditionFailure("NSPopUpButton did not retain the appended model item")
    }
    item.representedObject = modelID
    item.toolTip = toolTip
    return item
  }

  private func appendSeparator() {
    menu?.addItem(.separator())
  }

  @objc private func selectionChanged() {
    guard let selectedItem, selectedItem.isEnabled else { return }
    updateAccessibilityValue()
    onSelection?(selectedModelID)
  }

  private func updateAccessibilityValue() {
    setAccessibilityValue(titleOfSelectedItem ?? "")
  }
}
