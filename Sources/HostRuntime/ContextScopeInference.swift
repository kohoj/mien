import Foundation
import MienContracts

public struct ContextScopeInference: Sendable {
  public init() {}

  public func infer(intent: String, snapshot: InvocationSnapshot) -> ContextScope {
    if snapshot.selectedText?.isEmpty == false { return .selection }

    let normalized = intent.lowercased()
    let historySignals = [
      "完整聊天", "全部聊天", "聊天记录", "更早", "历史消息", "长图",
      "full conversation", "chat history", "earlier messages", "entire thread",
    ]
    if historySignals.contains(where: normalized.contains) { return .boundedHistory }

    let conversationSignals = [
      "回复", "回消息", "对话", "聊天", "总结这段", "总结当前",
      "reply", "respond", "conversation", "this thread",
    ]
    if conversationSignals.contains(where: normalized.contains)
      || snapshot.pointedElement?.ancestorRoles.contains("AXScrollArea") == true
    {
      return .conversation
    }
    return snapshot.pointedElement == nil ? .window : .semanticRegion
  }
}
