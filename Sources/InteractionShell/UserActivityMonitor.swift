import AppKit
import CoreGraphics
import Foundation

@MainActor
final class UserActivityMonitor {
  private static let longviewEventTag: Int64 = 0x4846_5343_524F_4C4C
  private static let mask: NSEvent.EventTypeMask = [
    .keyDown,
    .leftMouseDown,
    .rightMouseDown,
    .otherMouseDown,
    .scrollWheel,
  ]

  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var onActivity: (() -> Void)?

  func start(onActivity: @escaping () -> Void) {
    stop()
    self.onActivity = onActivity
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] event in
      Task { @MainActor in self?.observe(event) }
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mask) { [weak self] event in
      self?.observe(event)
      return event
    }
  }

  func stop() {
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    globalMonitor = nil
    localMonitor = nil
    onActivity = nil
  }

  private func observe(_ event: NSEvent) {
    if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Self.longviewEventTag {
      return
    }
    let callback = onActivity
    stop()
    callback?()
  }
}
