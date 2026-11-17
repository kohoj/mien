import AppKit
import WebKit
import XCTest

@testable import InteractionShell

@MainActor
final class ResultWebRendererTests: XCTestCase {
  func testResultUsesItsNativeWindowAppearanceBeforeBecomingVisible() async throws {
    for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.appearance = NSAppearance(named: appearance)
      let renderer = ResultWebRendererView()
      window.contentView = renderer
      window.orderFront(nil)
      defer { window.orderOut(nil) }
      renderer.render("## 已验证的结果\n\n浅色与深色都应保持可读。")
      let webView = try XCTUnwrap(renderer.subviews.compactMap { $0 as? WKWebView }.first)
      XCTAssertTrue(webView.isHidden, "Do not flash an unthemed page during navigation")
      let deadline = ContinuousClock.now.advanced(by: .seconds(4))
      while !renderer.isReadyForSnapshot && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTAssertTrue(renderer.isReadyForSnapshot)
      XCTAssertFalse(webView.isHidden)
      let scheme =
        try await webView.evaluateJavaScript(
          "getComputedStyle(document.documentElement).colorScheme") as? String
      XCTAssertEqual(scheme, appearance == .darkAqua ? "dark" : "light")
      let background =
        try await webView.evaluateJavaScript(
          "getComputedStyle(document.body).backgroundColor.match(/[\\d.]+/g).slice(0, 3).map(Number)"
        )
        as? [Double]
      let channels = try XCTUnwrap(background)
      XCTAssertEqual(channels.count, 3)
      XCTAssertTrue(channels.allSatisfy { appearance == .darkAqua ? $0 < 50 : $0 > 230 })
      renderer.releaseResources()
    }
  }

  func testPackagedRendererDeclaresAnOfflineContentSecurityPolicy() throws {
    let indexURL = try XCTUnwrap(ResultWebRendererView.rendererIndexURLForTesting())
    let source = try String(contentsOf: indexURL, encoding: .utf8)

    XCTAssertTrue(source.contains("default-src 'none'"))
    XCTAssertTrue(source.contains("connect-src 'none'"))
    XCTAssertTrue(source.contains("img-src 'none'"))
    XCTAssertTrue(source.contains("object-src 'none'"))
  }
}
