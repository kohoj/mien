import AppKit
import CoreGraphics
import Foundation

@MainActor
final class UserActivityMonitor {
  enum EventOrigin {
    case global
    case local
  }

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
  private var ownedWindowNumbers: Set<Int> = []
  private var onActivity: (() -> Void)?

  /// Begins observing user input outside the supplied Mien windows.
  ///
  /// Local monitor callbacks run before AppKit's responder chain. Keeping the
  /// ownership boundary here ensures input aimed at Mien remains untouched,
  /// while input delivered to another app still transfers control immediately.
  func start(ownedWindows: [NSWindow], onActivity: @escaping () -> Void) {
    stop()
    ownedWindowNumbers = Set(ownedWindows.map(\.windowNumber))
    self.onActivity = onActivity
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] event in
      Task { @MainActor in self?.observe(event, origin: .global) }
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mask) { [weak self] event in
      self?.observe(event, origin: .local)
      return event
    }
  }

  func stop() {
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    globalMonitor = nil
    localMonitor = nil
    ownedWindowNumbers.removeAll()
    onActivity = nil
  }

  func observe(_ event: NSEvent, origin: EventOrigin) {
    guard
      Self.shouldTriggerTakeover(
        for: event,
        origin: origin,
        ownedWindowNumbers: ownedWindowNumbers
      )
    else {
      return
    }
    let callback = onActivity
    stop()
    callback?()
  }

  static func shouldTriggerTakeover(
    for event: NSEvent,
    origin: EventOrigin,
    ownedWindowNumbers: Set<Int>
  ) -> Bool {
    if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == longviewEventTag {
      return false
    }
    if origin == .local, ownedWindowNumbers.contains(event.windowNumber) {
      return false
    }
    return true
  }
}
