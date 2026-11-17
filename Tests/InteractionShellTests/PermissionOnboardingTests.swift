import AppKit
import CoreGraphics
import MienContracts
import PermissionKernel
import XCTest

@testable import InteractionShell

final class PermissionOnboardingTests: XCTestCase {
  private var availableModels: AgentModelReadiness {
    .available(
      catalog: AgentModelCatalog(
        currentModelID: "openai-codex/test",
        options: [AgentModelOption(id: "openai-codex/test", name: "Test")]
      ), preferredModelID: nil
    )
  }

  @MainActor
  func testCatalogFailureDoesNotInventAnUnavailableSelectionOrClearPreference() {
    let picker = AgentModelPicker()
    var selections = 0
    picker.onSelection = { _ in selections += 1 }
    picker.apply(.failed(preferredModelID: "openai-codex/saved"))
    XCTAssertEqual(picker.titleOfSelectedItem, "模型列表读取失败")
    XCTAssertFalse(picker.isEnabled)
    XCTAssertEqual(selections, 0)
    for models in [
      AgentModelReadiness.notLoaded(preferredModelID: nil), .loading(preferredModelID: nil),
    ] {
      XCTAssertFalse(models.isUsable)
    }
  }

  @MainActor
  func testModelPickerUsesNativeMenuSelectionAndEmitsTheExactPreference() throws {
    _ = NSApplication.shared
    let picker = AgentModelPicker()
    let readiness = AgentModelReadiness.available(
      catalog: AgentModelCatalog(
        currentModelID: "openai-codex/gpt-5.5",
        options: [
          AgentModelOption(id: "openai-codex/gpt-5.5", name: "GPT-5.5"),
          AgentModelOption(id: "openai-codex/gpt-5.6-sol", name: "GPT-5.6 Sol"),
        ]
      ),
      preferredModelID: nil
    )
    picker.apply(readiness)

    var emissionCount = 0
    var emittedModelID: String?
    picker.onSelection = { modelID in
      emissionCount += 1
      emittedModelID = modelID
    }

    let solIndex = picker.indexOfItem(withTitle: "GPT-5.6 Sol")
    XCTAssertNotEqual(solIndex, -1)
    let solItem = try XCTUnwrap(picker.item(at: solIndex))
    XCTAssertNotNil(solItem.action)
    XCTAssertTrue(solItem.target === picker.cell)

    picker.menu?.performActionForItem(at: solIndex)
    XCTAssertEqual(picker.selectedModelID, "openai-codex/gpt-5.6-sol")
    XCTAssertEqual(emissionCount, 1)
    XCTAssertEqual(emittedModelID, "openai-codex/gpt-5.6-sol")

    let defaultIndex = picker.indexOfItem(withTitle: "默认 · GPT-5.5")
    XCTAssertNotEqual(defaultIndex, -1)
    picker.menu?.performActionForItem(at: defaultIndex)
    XCTAssertNil(picker.selectedModelID)
    XCTAssertEqual(emissionCount, 2)
    XCTAssertNil(emittedModelID)
  }

  @MainActor
  func testUnchangedReadinessDoesNotInvalidateAnOpenModelMenu() throws {
    _ = NSApplication.shared
    let picker = AgentModelPicker()
    let readiness = AgentModelReadiness.available(
      catalog: AgentModelCatalog(
        currentModelID: "openai-codex/gpt-5.5",
        options: [
          AgentModelOption(id: "openai-codex/gpt-5.5", name: "GPT-5.5"),
          AgentModelOption(id: "openai-codex/gpt-5.6-sol", name: "GPT-5.6 Sol"),
        ]
      ),
      preferredModelID: nil
    )
    picker.apply(readiness)
    let originalItem = try XCTUnwrap(picker.item(withTitle: "GPT-5.6 Sol"))

    picker.apply(readiness)

    XCTAssertTrue(originalItem === picker.item(withTitle: "GPT-5.6 Sol"))
  }

  @MainActor
  func testUnavailableModelCanReturnToTheAgentDefaultThroughTheNativeMenu() throws {
    _ = NSApplication.shared
    let picker = AgentModelPicker()
    picker.apply(
      .available(
        catalog: AgentModelCatalog(
          currentModelID: "openai-codex/gpt-5.5",
          options: [AgentModelOption(id: "openai-codex/gpt-5.5", name: "GPT-5.5")]
        ),
        preferredModelID: "openai-codex/retired"
      )
    )
    XCTAssertEqual(picker.titleOfSelectedItem, "所选模型不可用")
    XCTAssertFalse(try XCTUnwrap(picker.selectedItem).isEnabled)

    var didEmit = false
    var emittedModelID: String? = "not-default"
    picker.onSelection = { modelID in
      didEmit = true
      emittedModelID = modelID
    }
    let defaultIndex = picker.indexOfItem(withTitle: "默认 · GPT-5.5")
    XCTAssertNotEqual(defaultIndex, -1)
    picker.menu?.performActionForItem(at: defaultIndex)

    XCTAssertTrue(didEmit)
    XCTAssertNil(emittedModelID)
  }

  @MainActor
  func testModelPreferenceHasOneDurableDefaultOrExactID() {
    let suiteName = "mien-model-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AgentModelPreferenceStore(defaults: defaults)

    XCTAssertNil(store.modelID)
    store.setModelID("gpt-primary")
    XCTAssertEqual(store.modelID, "gpt-primary")
    store.setModelID(nil)
    XCTAssertNil(store.modelID)
  }

  func testUnavailableExplicitModelBlocksReadinessUntilUserChooses() {
    let catalog = AgentModelCatalog(
      currentModelID: "gpt-primary",
      options: [AgentModelOption(id: "gpt-primary", name: "Primary")]
    )
    let permissions = DesktopPermissionReadiness(
      accessibility: .authorized,
      screenRecording: .authorized
    )
    let invalid = MienReadinessSnapshot(
      agent: .connected(agentName: "Codex 已连接"),
      models: .available(catalog: catalog, preferredModelID: "retired-model"),
      permissions: permissions
    )
    let defaulted = MienReadinessSnapshot(
      agent: .connected(agentName: "Codex 已连接"),
      models: .failed(preferredModelID: nil),
      permissions: permissions
    )

    XCTAssertFalse(invalid.canUse)
    XCTAssertEqual(invalid.nextAction, .chooseModel)
    XCTAssertFalse(defaulted.canUse)
    XCTAssertEqual(defaulted.nextAction, .refreshModels)
  }

  func testFirstRunPresentsEvenWhenPermissionsAlreadyExist() {
    let ready = MienReadinessSnapshot(
      agent: .connected(agentName: "Codex 已连接"),
      models: availableModels,
      permissions: DesktopPermissionReadiness(
        accessibility: .authorized,
        screenRecording: .authorized
      )
    )

    XCTAssertTrue(
      MienOnboardingDecision.shouldPresent(
        hasSeenIntroduction: false,
        readiness: ready
      )
    )
    XCTAssertFalse(
      MienOnboardingDecision.shouldPresent(
        hasSeenIntroduction: true,
        readiness: ready
      )
    )
  }

  func testOneSensingRouteKeepsMienUsableWithoutInventingAReadinessBit() {
    let revoked = DesktopPermissionReadiness(
      accessibility: .authorized,
      screenRecording: .deniedOrNotRequested
    )

    let readiness = MienReadinessSnapshot(
      agent: .connected(agentName: "Codex 已连接"),
      models: availableModels,
      permissions: revoked
    )

    XCTAssertFalse(
      MienOnboardingDecision.shouldPresent(
        hasSeenIntroduction: true,
        readiness: readiness
      )
    )
    XCTAssertTrue(readiness.canUse)
    XCTAssertFalse(readiness.isFullyReady)
    XCTAssertFalse(revoked.isReady)
    XCTAssertEqual(revoked.remainingCount, 1)
    XCTAssertEqual(revoked.status(for: .screenRecording), .deniedOrNotRequested)
  }

  func testDisconnectedAgentAlwaysReopensReadiness() {
    let readiness = MienReadinessSnapshot(
      agent: .authenticationRequired,
      permissions: DesktopPermissionReadiness(
        accessibility: .authorized,
        screenRecording: .authorized
      )
    )

    XCTAssertTrue(
      MienOnboardingDecision.shouldPresent(
        hasSeenIntroduction: true,
        readiness: readiness
      )
    )
    XCTAssertFalse(readiness.canUse)
  }

  func testTransientAgentConnectionDoesNotReplayCompletedIntroduction() {
    let readiness = MienReadinessSnapshot(
      agent: .connecting,
      permissions: DesktopPermissionReadiness(
        accessibility: .authorized,
        screenRecording: .authorized
      )
    )

    XCTAssertFalse(
      MienOnboardingDecision.shouldPresent(
        hasSeenIntroduction: true,
        readiness: readiness
      )
    )
    XCTAssertTrue(
      MienOnboardingDecision.shouldPresent(
        hasSeenIntroduction: false,
        readiness: readiness
      )
    )
  }

  func testReadinessWindowFollowsThePointerDisplayAndEverySpace() throws {
    let primary = NSRect(x: 0, y: 24, width: 1440, height: 876)
    let secondary = NSRect(x: 1440, y: -76, width: 1600, height: 976)

    let frame = try XCTUnwrap(
      MienReadinessWindowPolicy.frame(
        contentSize: NSSize(width: 620, height: 610),
        visibleFrames: [primary, secondary],
        pointer: NSPoint(x: 2000, y: 400)
      )
    )

    XCTAssertEqual(frame.midX, secondary.midX)
    XCTAssertEqual(frame.midY, secondary.midY)
    XCTAssertTrue(
      MienReadinessWindowPolicy.collectionBehavior.contains(.canJoinAllSpaces)
    )
    XCTAssertFalse(
      MienReadinessWindowPolicy.collectionBehavior.contains(.moveToActiveSpace)
    )
  }

  func testReadinessOwnsOneDeterministicNextAction() {
    let noPermissions = DesktopPermissionReadiness(
      accessibility: .deniedOrNotRequested,
      screenRecording: .deniedOrNotRequested
    )
    XCTAssertEqual(
      MienReadinessSnapshot(
        agent: .authenticationRequired,
        permissions: noPermissions
      ).nextAction,
      .connectAgent
    )
    XCTAssertEqual(
      MienReadinessSnapshot(
        agent: .connected(agentName: "Codex 已连接"),
        models: availableModels,
        permissions: noPermissions
      ).nextAction,
      .requestPermission(.accessibility)
    )
    XCTAssertEqual(
      MienReadinessSnapshot(
        agent: .connected(agentName: "Codex 已连接"),
        models: availableModels,
        permissions: DesktopPermissionReadiness(
          accessibility: .authorized,
          screenRecording: .deniedOrNotRequested
        )
      ).nextAction,
      .finish
    )
    XCTAssertEqual(
      MienReadinessSnapshot(
        agent: .connected(agentName: "Codex 已连接"),
        models: availableModels,
        permissions: DesktopPermissionReadiness(
          accessibility: .authorized,
          screenRecording: .authorized
        )
      ).nextAction,
      .finish
    )
    XCTAssertEqual(
      MienReadinessSnapshot(
        agent: .connected(agentName: "Codex 已连接"),
        models: availableModels,
        permissions: DesktopPermissionReadiness(
          accessibility: .deniedOrNotRequested,
          screenRecording: .authorized
        )
      ).nextAction,
      .finish
    )
  }

  func testReadinessFocusesOnlyThePermissionOwnedByItsNextAction() {
    let neither = MienReadinessSnapshot(
      agent: .connected(agentName: "Codex 已连接"),
      models: availableModels,
      permissions: DesktopPermissionReadiness(
        accessibility: .deniedOrNotRequested,
        screenRecording: .deniedOrNotRequested
      )
    )
    let accessibilityOnly = MienReadinessSnapshot(
      agent: .connected(agentName: "Codex 已连接"),
      models: availableModels,
      permissions: DesktopPermissionReadiness(
        accessibility: .authorized,
        screenRecording: .deniedOrNotRequested
      )
    )
    let ready = MienReadinessSnapshot(
      agent: .connected(agentName: "Codex 已连接"),
      models: availableModels,
      permissions: DesktopPermissionReadiness(
        accessibility: .authorized,
        screenRecording: .authorized
      )
    )

    XCTAssertEqual(neither.focusedPermission, .accessibility)
    XCTAssertNil(accessibilityOnly.focusedPermission)
    XCTAssertNil(ready.focusedPermission)
  }

  func testPermissionRoutesOwnTheExactPrivacyAnchors() {
    XCTAssertEqual(
      DesktopPermission.accessibility.settingsRoute.url?.absoluteString,
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
    )
    XCTAssertEqual(
      DesktopPermission.screenRecording.settingsRoute.url?.absoluteString,
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
    )
  }

  func testSettingsWindowGeometryUsesTheIntersectingDisplay() {
    let primary = ScreenGeometry(
      displayID: 1,
      coreGraphicsFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      appKitFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
      visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 876)
    )
    let secondary = ScreenGeometry(
      displayID: 2,
      coreGraphicsFrame: CGRect(x: 1440, y: -100, width: 1600, height: 1000),
      appKitFrame: CGRect(x: 1440, y: 0, width: 1600, height: 1000),
      visibleFrame: CGRect(x: 1440, y: 24, width: 1600, height: 976)
    )

    let result = SystemSettingsWindowGeometry.appKitFrame(
      from: CGRect(x: 1540, y: 0, width: 900, height: 700),
      screens: [primary, secondary]
    )

    XCTAssertEqual(result, CGRect(x: 1540, y: 200, width: 900, height: 700))
  }

  func testApplicationDragUsesFinderCompatiblePasteboardRepresentations() {
    let applicationURL = URL(fileURLWithPath: "/Applications/Mien.app")
    let writer = AppBundlePasteboardWriter(url: applicationURL)
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("mien-drag-test"))

    XCTAssertEqual(
      writer.writableTypes(for: pasteboard),
      [
        .fileURL,
        .URL,
        AppBundlePasteboardWriter.filenamesType,
        AppBundlePasteboardWriter.promisedFileURLType,
        .string,
      ]
    )
    XCTAssertEqual(
      writer.pasteboardPropertyList(forType: .fileURL) as? String,
      applicationURL.absoluteString
    )
    XCTAssertEqual(
      writer.pasteboardPropertyList(forType: AppBundlePasteboardWriter.filenamesType)
        as? [String],
      [applicationURL.path]
    )
    XCTAssertEqual(
      writer.pasteboardPropertyList(forType: .string) as? String,
      applicationURL.path
    )
  }

  func testGuideAlignsWithSystemSettingsContentPane() {
    let settingsFrame = CGRect(x: 200, y: 220, width: 800, height: 620)
    let visibleFrame = CGRect(x: 0, y: 24, width: 1440, height: 876)

    let result = SystemSettingsGuidePlacement.frame(
      settingsFrame: settingsFrame,
      panelHeight: 132,
      visibleFrame: visibleFrame
    )

    XCTAssertEqual(result, CGRect(x: 430, y: 88, width: 570, height: 132))
  }

  func testGuideStaysVisibleWhenSettingsReachesScreenBottom() {
    let result = SystemSettingsGuidePlacement.frame(
      settingsFrame: CGRect(x: 40, y: 18, width: 900, height: 760),
      panelHeight: 132,
      visibleFrame: CGRect(x: 0, y: 24, width: 1000, height: 776)
    )

    XCTAssertEqual(result.minY, 36)
    XCTAssertGreaterThanOrEqual(result.minX, 12)
    XCTAssertLessThanOrEqual(result.maxX, 988)
  }

  func testLaunchFramePreservesTheTriggeringControlAsItsOrigin() {
    let source = CGRect(x: 900, y: 420, width: 86, height: 28)
    let result = SystemSettingsGuidePlacement.launchFrame(
      sourceFrame: source,
      panelSize: CGSize(width: 420, height: 132)
    )

    XCTAssertEqual(result.midX, source.midX)
    XCTAssertEqual(result.midY, source.midY)
    XCTAssertEqual(result.width, 243.6, accuracy: 0.001)
    XCTAssertEqual(result.height, 76.56, accuracy: 0.001)
  }
}
