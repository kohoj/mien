import MienContracts
import PolicyKernel
import XCTest

final class PolicyEngineTests: XCTestCase {
  func testPasswordManagersFailClosedBeforePromptOrModelPolicy() {
    let decision = PolicyEngine().evaluate(
      makeRequest(
        bundleIdentifier: "com.1password.1password",
        operation: .readAccessibility
      ))

    XCTAssertEqual(decision, .deny(reason: "application is excluded by deterministic policy"))
  }

  func testExternalCommitRequiresApprovalAtTheConsequence() {
    let engine = PolicyEngine()
    XCTAssertEqual(
      engine.evaluate(makeRequest(operation: .externalCommit)),
      .requireApproval(reason: "confirm the exact external consequence")
    )
    XCTAssertEqual(
      engine.evaluate(
        makeRequest(
          operation: .externalCommit,
          approvalReference: "approval:send-to-lin"
        )),
      .allow(reason: "request is within the explicit task and destination scope")
    )
  }

  func testSensitiveContentCannotBeTransmittedByDefault() {
    let decision = PolicyEngine().evaluate(
      makeRequest(
        operation: .transmit,
        sensitivity: .sensitive,
        destination: .codex
      ))

    XCTAssertEqual(decision, .deny(reason: "sensitive content cannot leave the host boundary"))
  }

  func testLocalSensitiveAllowlistCannotAuthorizeRemoteTransmission() {
    let engine = PolicyEngine(
      configuration: PolicyConfiguration(
        locallyAllowedSensitiveBundleIdentifiers: ["com.example.bank"]
      ))
    let decision = engine.evaluate(
      makeRequest(
        bundleIdentifier: "com.example.bank",
        operation: .transmit,
        sensitivity: .sensitive,
        destination: .codex
      ))

    XCTAssertEqual(decision, .deny(reason: "sensitive content cannot leave the host boundary"))
  }

  func testSurfaceClassifierFailsClosedForSecureAndSensitiveApplications() {
    let classifier = SurfaceSensitivityClassifier()

    XCTAssertEqual(
      classifier.classify(
        bundleIdentifier: "com.example.chat",
        semanticTarget: AXElementFingerprint(role: "AXSecureTextField")
      ),
      .secret
    )
    XCTAssertEqual(
      classifier.classify(
        bundleIdentifier: "com.example.bank.mobile",
        semanticTarget: nil
      ),
      .sensitive
    )
  }

  private func makeRequest(
    bundleIdentifier: String = "com.apple.mail",
    operation: PolicyOperation,
    sensitivity: Sensitivity = .userContent,
    destination: PolicyDestination = .externalApplication,
    approvalReference: String? = nil
  ) -> PolicyRequest {
    PolicyRequest(
      taskID: UUID(),
      subject: PolicySubject(
        bundleIdentifier: bundleIdentifier,
        windowID: 42,
        scope: .conversation,
        protectedContent: false
      ),
      operation: operation,
      sensitivity: sensitivity,
      destination: destination,
      userInitiated: true,
      approvalReference: approvalReference
    )
  }
}
