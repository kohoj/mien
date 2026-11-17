import Foundation
import HostRuntime
import XCTest

final class PiCodexCredentialImporterTests: XCTestCase {
  func testImporterConvertsOnlyCodexSubscriptionAuthAndRepairsAnEmptyPiStore() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try writePrivateJSON([:], to: fixture.piHome.appendingPathComponent("auth.json"))
    try writePrivateJSON(
      codexCredential(accountID: "account-1"),
      to: fixture.codexHome.appendingPathComponent("auth.json")
    )
    try Data("must-not-copy".utf8).write(
      to: fixture.codexHome.appendingPathComponent("config.toml")
    )

    let importer = PiCodexCredentialImporter()
    let result = try importer.prepare(codexHome: fixture.codexHome, piHome: fixture.piHome)

    XCTAssertEqual(result, .installed)
    XCTAssertTrue(try importer.validate(piHome: fixture.piHome))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.piHome.appendingPathComponent("config.toml").path
      )
    )
    let attributes = try FileManager.default.attributesOfItem(
      atPath: fixture.piHome.appendingPathComponent("auth.json").path
    )
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testImporterNeverOverwritesAnExistingValidPiCredential() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let destination = fixture.piHome.appendingPathComponent("auth.json")
    let existing: [String: Any] = [
      "openai-codex": [
        "type": "oauth",
        "access": "existing-access",
        "refresh": "existing-refresh",
        "expires": 4_000_000_000_000,
        "accountId": "existing-account",
      ]
    ]
    try writePrivateJSON(existing, to: destination)
    let original = try Data(contentsOf: destination)

    let result = try PiCodexCredentialImporter().prepare(
      codexHome: fixture.codexHome,
      piHome: fixture.piHome
    )

    XCTAssertEqual(result, .alreadyPresent)
    XCTAssertEqual(try Data(contentsOf: destination), original)
  }

  func testImporterRejectsAnAccountIDThatDoesNotMatchTheSignedTokenClaim() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try writePrivateJSON(
      codexCredential(accountID: "substituted-account", tokenAccountID: "account-1"),
      to: fixture.codexHome.appendingPathComponent("auth.json")
    )

    XCTAssertThrowsError(
      try PiCodexCredentialImporter().prepare(
        codexHome: fixture.codexHome,
        piHome: fixture.piHome
      )
    ) { error in
      XCTAssertEqual(error as? PiCodexCredentialImportError, .invalidCodexCredential)
    }
  }

  private func makeFixture() throws -> (root: URL, codexHome: URL, piHome: URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let codexHome = root.appendingPathComponent("Codex", isDirectory: true)
    let piHome = root.appendingPathComponent("Pi", isDirectory: true)
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: piHome, withIntermediateDirectories: true)
    return (root, codexHome, piHome)
  }

  private func codexCredential(
    accountID: String,
    tokenAccountID: String? = nil
  ) throws -> [String: Any] {
    let payload: [String: Any] = [
      "exp": 4_000_000_000,
      "https://api.openai.com/auth": [
        "chatgpt_account_id": tokenAccountID ?? accountID
      ],
    ]
    let header = try base64URL(["alg": "none"])
    let body = try base64URL(payload)
    return [
      "auth_mode": "chatgpt",
      "tokens": [
        "access_token": "\(header).\(body).signature",
        "refresh_token": "refresh-fixture",
        "account_id": accountID,
        "id_token": "not-imported",
      ],
      "last_refresh": "not-imported",
    ]
  }

  private func base64URL(_ object: [String: Any]) throws -> String {
    try JSONSerialization.data(withJSONObject: object)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private func writePrivateJSON(_ object: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
