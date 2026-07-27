import CryptoKit
import Foundation
import Security

public enum ExecutableIntegrityError: Error, Equatable, Sendable {
  case unavailable
  case invalidDigest
  case digestMismatch
  case invalidCodeSignature(OSStatus)
}

public enum ExecutableIntegrity {
  public static func verify(
    _ executableURL: URL,
    expectedSHA256: String,
    requireValidCodeSignature: Bool = false
  ) throws {
    guard executableURL.isFileURL,
      FileManager.default.isExecutableFile(atPath: executableURL.path),
      let data = try? Data(contentsOf: executableURL, options: [.mappedIfSafe])
    else {
      throw ExecutableIntegrityError.unavailable
    }
    let expected = expectedSHA256.lowercased()
    guard expected.count == 64, expected.allSatisfy(\.isHexDigit) else {
      throw ExecutableIntegrityError.invalidDigest
    }
    let observed = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    guard observed == expected else { throw ExecutableIntegrityError.digestMismatch }

    if requireValidCodeSignature {
      var code: SecStaticCode?
      var codeStatus = SecStaticCodeCreateWithPath(
        executableURL as CFURL,
        SecCSFlags(),
        &code
      )
      if codeStatus == errSecSuccess, let code {
        codeStatus = SecStaticCodeCheckValidity(code, SecCSFlags(), nil)
      }
      guard codeStatus == errSecSuccess else {
        throw ExecutableIntegrityError.invalidCodeSignature(codeStatus)
      }
    }
  }
}
