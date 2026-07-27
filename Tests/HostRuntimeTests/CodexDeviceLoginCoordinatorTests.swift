import Foundation
import XCTest

@testable import HostRuntime

final class CodexDeviceLoginCoordinatorTests: XCTestCase {
  func testParserWaitsForBothURLAndCompleteCodeAcrossChunks() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let accumulator = DeviceLoginOutputAccumulator { _ in }

    await accumulator.ingest(
      Data("Open https://auth.openai.com/codex/device and enter ABCD-".utf8),
      now: now
    )
    let publishedBeforeCode = await accumulator.didPublishAuthorization
    XCTAssertFalse(publishedBeforeCode)

    await accumulator.ingest(Data("EFGH1\n".utf8), now: now)

    let publishedAfterCode = await accumulator.didPublishAuthorization
    XCTAssertTrue(publishedAfterCode)
  }

  func testParserRemovesTerminalColorWithoutAcceptingAnotherOrigin() throws {
    let now = Date(timeIntervalSince1970: 2_000)
    let text = """
      \u{001B}[94mhttps://auth.openai.com/codex/device\u{001B}[0m
      \u{001B}[94mTL3K-CWLL6\u{001B}[0m
      """

    let authorization = try XCTUnwrap(DeviceLoginOutputParser.parse(text, now: now))

    XCTAssertEqual(
      authorization.verificationURL.absoluteString, "https://auth.openai.com/codex/device")
    XCTAssertEqual(authorization.userCode, "TL3K-CWLL6")
    XCTAssertEqual(authorization.expiresAt, now.addingTimeInterval(15 * 60))
    XCTAssertNil(
      DeviceLoginOutputParser.parse(
        "https://example.com/codex/device\nTL3K-CWLL6",
        now: now
      ))
  }
}
