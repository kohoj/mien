import Foundation
import MienContracts

public struct ContextDisclosureFormatter: Sendable {
  public init() {}

  public func label(for manifest: ContextManifest) -> String {
    let destination = manifest.remoteTransmissionAllowed ? "Codex 将使用" : "仅在本机读取"
    var components = [scopeLabel(manifest.resolvedScope)]
    let sourceLabels = orderedUnique(manifest.artifacts.map { sourceLabel($0.provider) })
    components.append(contentsOf: sourceLabels)
    if !manifest.omittedScopes.isEmpty || manifest.artifacts.contains(where: { !$0.complete }) {
      components.append("部分可用")
    }
    return "\(destination)：\(components.joined(separator: " · "))"
  }

  private func scopeLabel(_ scope: ContextScope) -> String {
    switch scope {
    case .selection: "选中内容"
    case .pointedElement: "指向内容"
    case .semanticRegion: "附近内容"
    case .conversation: "当前对话"
    case .window: "当前窗口"
    case .boundedHistory: "更多历史"
    case .relatedMemory: "相关记忆"
    case .multipleApplications: "多个应用"
    }
  }

  private func sourceLabel(_ provider: ContextProviderKind) -> String {
    switch provider {
    case .selection: "选中文字"
    case .accessibility: "界面文字"
    case .screenCapture: "可见画面"
    case .longview: "历史长图"
    case .localOCR: "本机识别文字"
    case .nativeConnector: "应用内容"
    case .memory: "已批准记忆"
    case .visualFallback: "视觉识别"
    }
  }

  private func orderedUnique(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { seen.insert($0).inserted }
  }
}
