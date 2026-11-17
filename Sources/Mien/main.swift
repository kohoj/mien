import AppKit

/// AppKit lifecycle adapter. Application services own their asynchronous work.
@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
  private let application = MienApplicationController()
  private var terminationInProgress = false

  func applicationDidFinishLaunching(_ notification: Notification) { application.start() }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminationInProgress else { return .terminateLater }
    terminationInProgress = true
    Task {
      await application.stop()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

@main
@MainActor
private enum MienMain {
  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
  }
}
