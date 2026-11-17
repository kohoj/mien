import AppKit
import Foundation
import OSLog
import WebKit

@MainActor
final class ResultWebRendererView: NSView {
  private enum Metrics {
    static let initialHeight: CGFloat = 22
    static let maximumHeight: CGFloat = 50_000
  }

  private static let logger = Logger(
    subsystem: "io.github.kohoj.mien",
    category: "ResultRenderer"
  )
  private static let websiteDataStore = WKWebsiteDataStore.nonPersistent()

  var onHeightChange: (() -> Void)?

  private var webView: WKWebView?
  private let messageHandler = WeakRendererMessageHandler()
  private let errorLabel = NSTextField(labelWithString: "无法显示 Agent 结果")
  private var markdown = ""
  private var contentHeight = Metrics.initialHeight
  private var contentHeightConstraint: NSLayoutConstraint!
  private var pageIsReady = false
  private var renderGeneration: UInt64 = 0
  private var renderedGeneration: UInt64 = 0
  private var hasMeasuredContent = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    translatesAutoresizingMaskIntoConstraints = false
    setContentHuggingPriority(.required, for: .vertical)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    contentHeightConstraint = heightAnchor.constraint(equalToConstant: contentHeight)
    contentHeightConstraint.isActive = true

    errorLabel.font = OverlayTypography.response
    errorLabel.textColor = .systemRed
    errorLabel.maximumNumberOfLines = 0
    errorLabel.isHidden = true
    errorLabel.translatesAutoresizingMaskIntoConstraints = false
    errorLabel.setAccessibilityLabel("Agent 结果显示失败")
    addSubview(errorLabel)

    NSLayoutConstraint.activate([
      errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
      errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
      errorLabel.topAnchor.constraint(equalTo: topAnchor),
      errorLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

  }

  required init?(coder: NSCoder) { nil }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    guard pageIsReady, !markdown.isEmpty else { return }
    renderMarkdown()
  }

  func render(_ markdown: String) {
    guard self.markdown != markdown else { return }
    self.markdown = markdown
    if markdown.isEmpty {
      releaseResources()
      return
    }
    if webView == nil, !markdown.isEmpty { loadRenderer() }
    guard pageIsReady else { return }
    renderMarkdown()
  }

  func clear() {
    render("")
  }

  var measuredHeight: CGFloat { contentHeight }
  var renderedMarkdownForTesting: String { markdown }
  var isReadyForSnapshot: Bool {
    markdown.isEmpty
      || (pageIsReady && hasMeasuredContent && renderedGeneration == renderGeneration)
  }

  func restoreMeasuredHeight(_ height: CGFloat) {
    guard height.isFinite, height > 0 else { return }
    contentHeight = min(Metrics.maximumHeight, height)
    contentHeightConstraint.constant = contentHeight
    invalidateIntrinsicContentSize()
  }

  func releaseResources() {
    renderGeneration &+= 1
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView?.uiDelegate = nil
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "mienRenderer")
    messageHandler.owner = nil
    webView?.removeFromSuperview()
    webView = nil
    pageIsReady = false
    hasMeasuredContent = false
    contentHeight = Metrics.initialHeight
    contentHeightConstraint.constant = contentHeight
    invalidateIntrinsicContentSize()
  }

  static func rendererIndexURLForTesting() -> URL? {
    rendererIndexURL()
  }

  fileprivate func receiveHeight(_ height: Any) {
    guard let number = height as? NSNumber else { return }
    let proposed = CGFloat(truncating: number)
    guard proposed.isFinite, proposed > 0 else { return }
    hasMeasuredContent = true
    let bounded = min(Metrics.maximumHeight, ceil(proposed))
    guard abs(bounded - contentHeight) >= 1 else { return }
    contentHeight = bounded
    contentHeightConstraint.constant = bounded
    invalidateIntrinsicContentSize()
    onHeightChange?()
  }

  private func loadRenderer() {
    guard let indexURL = Self.rendererIndexURL() else {
      showFailure("resource_missing")
      return
    }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = Self.websiteDataStore
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    let webView = WKWebView(frame: .zero, configuration: configuration)
    self.webView = webView
    webView.isHidden = true
    messageHandler.owner = self
    configuration.userContentController.add(messageHandler, name: "mienRenderer")
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.underPageBackgroundColor = .clear
    webView.translatesAutoresizingMaskIntoConstraints = false
    webView.setAccessibilityLabel("Agent 结果")
    addSubview(webView)

    NSLayoutConstraint.activate([
      webView.leadingAnchor.constraint(equalTo: leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: trailingAnchor),
      webView.topAnchor.constraint(equalTo: topAnchor),
      webView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
  }

  private func renderMarkdown() {
    guard let webView else { return }
    renderGeneration &+= 1
    let generation = renderGeneration
    let arguments: [String: Any] = [
      "markdown": markdown,
      "theme": themeTokens(),
    ]
    webView.callAsyncJavaScript(
      "window.mien.render(markdown, theme)",
      arguments: arguments,
      in: nil,
      in: .page
    ) { [weak self] result in
      Task { @MainActor in
        guard let self, self.renderGeneration == generation else { return }
        if case .failure(let error) = result {
          let nsError = error as NSError
          Self.logger.error(
            "result_renderer_render_failed generation=\(generation, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
          )
          self.showFailure("javascript_failed")
        } else {
          self.renderedGeneration = generation
          self.webView?.isHidden = false
        }
      }
    }
  }

  private func themeTokens() -> [String: Any] {
    var tokens: [String: Any] = [:]
    effectiveAppearance.performAsCurrentDrawingAppearance {
      tokens = [
        "label": Self.cssColor(.labelColor),
        "background": Self.cssColor(MienAppearance.paper),
        "colorScheme": effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          ? "dark" : "light",
        "secondaryLabel": Self.cssColor(.secondaryLabelColor),
        "tertiaryLabel": Self.cssColor(.tertiaryLabelColor),
        "separator": Self.cssColor(.separatorColor),
        "link": Self.cssColor(.linkColor),
        "codeBackground": Self.cssColor(.quaternaryLabelColor.withAlphaComponent(0.15)),
        "selection": Self.cssColor(.selectedTextBackgroundColor.withAlphaComponent(0.55)),
        "fontSize": OverlayTypography.response.pointSize,
      ]
    }
    return tokens
  }

  private func showFailure(_ reason: StaticString) {
    pageIsReady = false
    webView?.isHidden = true
    errorLabel.isHidden = false
    contentHeight = ceil(OverlayMetrics.resultLineHeight)
    contentHeightConstraint.constant = contentHeight
    invalidateIntrinsicContentSize()
    onHeightChange?()
    Self.logger.error("result_renderer_unavailable reason=\(reason, privacy: .public)")
  }

  private static func rendererIndexURL() -> URL? {
    if let resourceURL = Bundle.main.resourceURL {
      let installed =
        resourceURL
        .appendingPathComponent("ResultRenderer", isDirectory: true)
        .appendingPathComponent("index.html", isDirectory: false)
      if FileManager.default.isReadableFile(atPath: installed.path) {
        return installed
      }
    }
    return Bundle.module.url(
      forResource: "index",
      withExtension: "html",
      subdirectory: "ResultRenderer"
    )
  }

  private static func cssColor(_ color: NSColor) -> String {
    guard let rgb = color.usingColorSpace(.deviceRGB) else { return "rgba(0,0,0,0)" }
    return String(
      format: "rgba(%.5f,%.5f,%.5f,%.5f)",
      rgb.redComponent * 255,
      rgb.greenComponent * 255,
      rgb.blueComponent * 255,
      rgb.alphaComponent
    )
  }
}

@MainActor
private final class WeakRendererMessageHandler: NSObject, WKScriptMessageHandler {
  weak var owner: ResultWebRendererView?

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard message.frameInfo.isMainFrame,
      let body = message.body as? [String: Any],
      body["type"] as? String == "height",
      let height = body["height"]
    else { return }
    owner?.receiveHeight(height)
  }
}

extension ResultWebRendererView: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    if navigationAction.navigationType == .other,
      navigationAction.targetFrame?.isMainFrame == true,
      navigationAction.request.url?.isFileURL == true
    {
      decisionHandler(.allow)
      return
    }
    guard navigationAction.navigationType == .linkActivated,
      let url = navigationAction.request.url,
      let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "mailto"
    else {
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.cancel)
    NSWorkspace.shared.open(url)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    pageIsReady = true
    errorLabel.isHidden = true
    renderMarkdown()
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: any Error
  ) {
    let nsError = error as NSError
    Self.logger.error(
      "result_renderer_navigation_failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
    )
    showFailure("navigation_failed")
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    let nsError = error as NSError
    Self.logger.error(
      "result_renderer_provisional_navigation_failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
    )
    showFailure("provisional_navigation_failed")
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    showFailure("process_terminated")
  }
}

extension ResultWebRendererView: WKUIDelegate {
  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if navigationAction.navigationType == .linkActivated,
      let url = navigationAction.request.url,
      let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "mailto"
    {
      NSWorkspace.shared.open(url)
    }
    return nil
  }
}
