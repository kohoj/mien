import Carbon
import Foundation

public enum GlobalShortcutError: Error, Equatable, Sendable {
  case registrationFailed(OSStatus)
  case eventHandlerInstallationFailed(OSStatus)
}

@MainActor
public final class GlobalShortcutRegistrar {
  public struct Shortcut: Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(
      keyCode: UInt32 = UInt32(kVK_Space),
      modifiers: UInt32 = UInt32(controlKey | optionKey)
    ) {
      self.keyCode = keyCode
      self.modifiers = modifiers
    }

    public static let `default` = Shortcut()
  }

  public var onPress: (@MainActor () -> Void)?
  public var onRelease: (@MainActor () -> Void)?

  private var hotKey: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?

  public init() {}

  public func register(_ shortcut: Shortcut = .default) throws {
    unregister()
    let eventTypes = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
      ),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyReleased)
      ),
    ]
    let handlerStatus = eventTypes.withUnsafeBufferPointer { pointer in
      InstallEventHandler(
        GetApplicationEventTarget(),
        mienHotKeyHandler,
        pointer.count,
        pointer.baseAddress,
        Unmanaged.passUnretained(self).toOpaque(),
        &eventHandler
      )
    }
    guard handlerStatus == noErr else {
      throw GlobalShortcutError.eventHandlerInstallationFailed(handlerStatus)
    }

    let hotKeyID = EventHotKeyID(signature: 0x4D49_454E, id: 1)  // MIEN
    let status = RegisterEventHotKey(
      shortcut.keyCode,
      shortcut.modifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKey
    )
    guard status == noErr else {
      unregister()
      throw GlobalShortcutError.registrationFailed(status)
    }
  }

  public func unregister() {
    if let hotKey {
      UnregisterEventHotKey(hotKey)
      self.hotKey = nil
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
  }

  fileprivate func handle(kind: UInt32) {
    switch kind {
    case UInt32(kEventHotKeyPressed): onPress?()
    case UInt32(kEventHotKeyReleased): onRelease?()
    default: break
    }
  }
}

private func mienHotKeyHandler(
  _ nextHandler: EventHandlerCallRef?,
  _ event: EventRef?,
  _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event, let userData else { return OSStatus(eventNotHandledErr) }
  let registrar = Unmanaged<GlobalShortcutRegistrar>.fromOpaque(userData).takeUnretainedValue()
  let kind = GetEventKind(event)
  DispatchQueue.main.async {
    registrar.handle(kind: kind)
  }
  return noErr
}
