import Foundation
import HostRuntime
import XCTest

final class CodexCredentialBootstrapTests: XCTestCase {
  func testValidationRejectsAnInsecureCredentialEvenWhenSourceEqualsDestination() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("CodexHome", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let auth = home.appendingPathComponent("auth.json")
    try Data(#"{"token":"secret"}"#.utf8).write(to: auth)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: auth.path)

    XCTAssertThrowsError(
      try CodexCredentialBootstrap().prepare(sourceHome: home, destinationHome: home)
    )
    XCTAssertThrowsError(try CodexCredentialBootstrap().validateCredentialHome(home))
  }
  func testBootstrapCopiesOnlyPrivateAuthenticationDocument() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source", isDirectory: true)
    let destination = root.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let auth = source.appendingPathComponent("auth.json")
    try Data(#"{"token":"fixture-only"}"#.utf8).write(to: auth)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
    try Data("must-not-copy".utf8).write(
      to: source.appendingPathComponent("config.toml")
    )

    let result = try CodexCredentialBootstrap().prepare(
      sourceHome: source,
      destinationHome: destination
    )

    XCTAssertEqual(result, .installed)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: destination.appendingPathComponent("auth.json").path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: destination.appendingPathComponent("config.toml").path)
    )
    let attributes = try FileManager.default.attributesOfItem(
      atPath: destination.appendingPathComponent("auth.json").path
    )
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testBootstrapNeverOverwritesProductOwnedCredentials() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source", isDirectory: true)
    let destination = root.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let sourceAuth = source.appendingPathComponent("auth.json")
    let destinationAuth = destination.appendingPathComponent("auth.json")
    try Data(#"{"token":"source"}"#.utf8).write(to: sourceAuth)
    try Data(#"{"token":"destination"}"#.utf8).write(to: destinationAuth)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceAuth.path)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: destinationAuth.path)

    let result = try CodexCredentialBootstrap().prepare(
      sourceHome: source,
      destinationHome: destination
    )

    XCTAssertEqual(result, .alreadyPresent)
    XCTAssertEqual(try Data(contentsOf: destinationAuth), Data(#"{"token":"destination"}"#.utf8))
  }

  func testBootstrapRejectsWorldReadableCredentials() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source", isDirectory: true)
    let destination = root.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let auth = source.appendingPathComponent("auth.json")
    try Data(#"{"token":"fixture-only"}"#.utf8).write(to: auth)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: auth.path)

    XCTAssertThrowsError(
      try CodexCredentialBootstrap().prepare(
        sourceHome: source,
        destinationHome: destination
      )
    ) { error in
      XCTAssertEqual(error as? CodexCredentialBootstrapError, .insecureSource)
    }
  }

  func testBootstrapRejectsSymlinkedCredentialHome() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let realSource = root.appendingPathComponent("real-source", isDirectory: true)
    let linkedSource = root.appendingPathComponent("linked-source", isDirectory: true)
    try FileManager.default.createDirectory(at: realSource, withIntermediateDirectories: true)
    let auth = realSource.appendingPathComponent("auth.json")
    try Data(#"{"token":"fixture-only"}"#.utf8).write(to: auth)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
    try FileManager.default.createSymbolicLink(at: linkedSource, withDestinationURL: realSource)

    XCTAssertThrowsError(
      try CodexCredentialBootstrap().prepare(
        sourceHome: linkedSource,
        destinationHome: root.appendingPathComponent("destination", isDirectory: true)
      )
    ) { error in
      XCTAssertEqual(error as? CodexCredentialBootstrapError, .symbolicLinkRejected)
    }
  }
}
