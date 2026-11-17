import Foundation

/// Serial ownership of a conversation's work and teardown. Replacing a turn
/// cancels its execution, but never cancels the cleanup it must wait behind.
@MainActor
public final class ConversationWorkQueue {
  private var tail: Task<Void, Never>?
  private var cancellableWork: [UUID: Task<Void, Never>] = [:]

  public init() {}

  public func submit(_ operation: @escaping @MainActor () async -> Void) {
    enqueue(cleanup: false, cancelPrevious: true, operation)
  }

  public func continueWith(_ operation: @escaping @MainActor () async -> Void) {
    enqueue(cleanup: false, cancelPrevious: false, operation)
  }

  public func cleanup(_ operation: @escaping @MainActor () async -> Void) {
    enqueue(cleanup: true, cancelPrevious: true, operation)
  }

  public func waitForIdle() async { await tail?.value }

  private func enqueue(
    cleanup: Bool, cancelPrevious: Bool,
    _ operation: @escaping @MainActor () async -> Void
  ) {
    let previous = tail
    if cancelPrevious { for task in cancellableWork.values { task.cancel() } }
    let id = UUID()
    let task = Task {
      defer { self.cancellableWork.removeValue(forKey: id) }
      await previous?.value
      guard cleanup || !Task.isCancelled else { return }
      await operation()
    }
    if !cleanup { cancellableWork[id] = task }
    tail = task
  }
}
