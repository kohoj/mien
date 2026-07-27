import Foundation
import InteractionShell
import MienContracts
import XCTest

final class ContextDisclosureTests: XCTestCase {
  func testDisclosureNamesDestinationScopeAndEveryDistinctSource() {
    let manifest = makeManifest(
      remoteTransmissionAllowed: true,
      providers: [.accessibility, .longview, .accessibility],
      omittedScopes: [:]
    )

    XCTAssertEqual(
      ContextDisclosureFormatter().label(for: manifest),
      "Codex 将使用：更多历史 · 界面文字 · 历史长图"
    )
  }

  func testDisclosureDeclaresLocalOnlyAndPartialContext() {
    let manifest = makeManifest(
      remoteTransmissionAllowed: false,
      providers: [.selection],
      omittedScopes: [.boundedHistory: "unavailable"]
    )

    XCTAssertEqual(
      ContextDisclosureFormatter().label(for: manifest),
      "仅在本机读取：更多历史 · 选中文字 · 部分可用"
    )
  }

  private func makeManifest(
    remoteTransmissionAllowed: Bool,
    providers: [ContextProviderKind],
    omittedScopes: [ContextScope: String]
  ) -> ContextManifest {
    let now = Date()
    let taskID = UUID()
    let targetLeaseID = UUID()
    return ContextManifest(
      taskID: taskID,
      targetLeaseID: targetLeaseID,
      requestedScope: .boundedHistory,
      resolvedScope: .boundedHistory,
      artifacts: providers.map { provider in
        ContextArtifact(
          taskID: taskID,
          targetLeaseID: targetLeaseID,
          kind: provider == .longview ? .image : .text,
          provider: provider,
          providerVersion: "1",
          capturedAt: now,
          coherenceGroup: taskID,
          scope: .boundedHistory,
          mediaType: provider == .longview ? "image/png" : "text/plain",
          privateURI: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)"),
          contentDigest: String(repeating: "a", count: 64),
          sourceTrust: .hostObserved,
          sensitivity: .userContent,
          confidence: 1,
          complete: true,
          retention: ArtifactRetention(
            expiresAt: now.addingTimeInterval(30),
            deleteAfterTask: true,
            memoryEligible: false
          )
        )
      },
      omittedScopes: omittedScopes,
      budget: ContextBudget(
        maximumArtifacts: 8,
        maximumBytes: 1_024,
        maximumTextCharacters: 1_024,
        deadline: now.addingTimeInterval(30)
      ),
      remoteTransmissionAllowed: remoteTransmissionAllowed,
      coherent: true,
      digest: String(repeating: "b", count: 64)
    )
  }
}
