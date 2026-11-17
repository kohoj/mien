import ACPGateway
import ArtifactStore
import Foundation
import HostRuntime
import InteractionShell
import OSLog
import ProviderAdapters
import TaskRuntime

struct PreparedMienRuntime: Sendable {
  let supportURL: URL
  let coordinator: DesktopTaskCoordinator
  let artifactStore: PrivateArtifactStore
  let agentBridge: PiAgentBridge?
  let longviewProvider: LongviewContextProvider?
  let readiness: AgentConnectionReadiness
}

/// Performs startup I/O on its own executor; no AppKit objects cross this boundary.
actor MienRuntimeBootstrap {
  private struct RuntimeDigests: Decodable {
    let piAgent: String
    let longview: String
  }
  private let bundleURL: URL
  private let resourceURL: URL?
  private let environment: [String: String]
  private let suppliedSupportURL: URL?
  private var agentUnavailableStatus = "Agent 运行时未安装"
  private let logger = Logger(subsystem: "io.github.kohoj.mien", category: "startup")

  init(bundleURL: URL, resourceURL: URL?, environment: [String: String], supportURL: URL? = nil) {
    self.bundleURL = bundleURL
    self.resourceURL = resourceURL
    self.environment = environment
    suppliedSupportURL = supportURL
  }

  func prepare() async throws -> PreparedMienRuntime {
    let clock = ContinuousClock()
    let start = clock.now
    let supportURL = try applicationSupportDirectory()
    let journal = try JSONLTaskEventJournal(
      fileURL: supportURL.appendingPathComponent("task-events.jsonl"))
    try await recoverInterruptedTasks(journal: journal, supportURL: supportURL)
    try Task.checkCancellation()
    let recovered = clock.now
    let store = try PrivateArtifactStore(
      rootURL: supportURL.appendingPathComponent("Artifacts", isDirectory: true))
    let coordinator = try DesktopTaskCoordinator(journal: journal)
    let agent = makeAgentBridge(applicationSupportURL: supportURL)
    try Task.checkCancellation()
    let longview = makeLongviewProvider(applicationSupportURL: supportURL, store: store)
    logger.info(
      "runtime_prepared recovery=\(String(describing: start.duration(to: recovered)), privacy: .public) verification=\(String(describing: recovered.duration(to: clock.now)), privacy: .public)"
    )
    return PreparedMienRuntime(
      supportURL: supportURL, coordinator: coordinator, artifactStore: store,
      agentBridge: agent, longviewProvider: longview,
      readiness: agent != nil
        ? .connecting
        : (agentUnavailableStatus == "需要连接 Codex 订阅" ? .authenticationRequired : .unavailable))
  }

  func applicationSupportDirectory() throws -> URL {
    let base =
      try suppliedSupportURL?.deletingLastPathComponent()
      ?? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
    let directory = suppliedSupportURL ?? base.appendingPathComponent("Mien", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    return directory
  }

  private func recoverInterruptedTasks(
    journal: JSONLTaskEventJournal,
    supportURL: URL
  ) async throws {
    try removeOrphanedConversationDirectories(supportURL: supportURL)
    _ = try await journal.repairTrailingRecord()
    let plans = try TaskRecoveryAuditor.plans(for: await journal.replay())
    for plan in plans {
      try removeResidualDirectory(
        taskID: plan.taskID,
        rootURL: supportURL.appendingPathComponent("Tasks", isDirectory: true)
      )
      try removeResidualDirectory(
        taskID: plan.taskID,
        rootURL: supportURL.appendingPathComponent("Artifacts", isDirectory: true)
      )
      let events = TaskRecoveryAuditor.recoveryEvents(
        for: plan,
        localResidueRemoved: true
      )
      try await journal.append(events)
    }
  }

  private func removeOrphanedConversationDirectories(supportURL: URL) throws {
    let root = supportURL.appendingPathComponent("Conversations", isDirectory: true)
      .standardizedFileURL
    guard FileManager.default.fileExists(atPath: root.path) else { return }
    for directory in try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) {
      let resolved = directory.standardizedFileURL
      guard resolved.deletingLastPathComponent() == root else {
        throw CocoaError(.fileWriteInvalidFileName)
      }
      try FileManager.default.removeItem(at: resolved)
    }
  }

  private func removeResidualDirectory(taskID: UUID, rootURL: URL) throws {
    let root = rootURL.standardizedFileURL
    let directory = root.appendingPathComponent(taskID.uuidString, isDirectory: true)
      .standardizedFileURL
    guard directory.deletingLastPathComponent() == root else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
    guard !FileManager.default.fileExists(atPath: directory.path) else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  func makeAgentBridge(applicationSupportURL: URL) -> PiAgentBridge? {
    agentUnavailableStatus = "Agent 运行时未安装"
    let helperDirectory =
      bundleURL
      .appendingPathComponent("Contents/Helpers", isDirectory: true)
    let agentOverride = developerOverride(named: "MIEN_PI_AGENT_PATH")
    let agentURL = agentOverride ?? helperDirectory.appendingPathComponent("mien-pi-agent")
    guard FileManager.default.isExecutableFile(atPath: agentURL.path) else {
      logger.error("runtime_unavailable component=piAgent reason=missing_executable")
      return nil
    }
    let bundled = agentOverride == nil
    let digests = bundled ? runtimeDigests() : nil
    if bundled {
      guard let digests,
        (try? ExecutableIntegrity.verify(
          agentURL,
          expectedSHA256: digests.piAgent,
          requireValidCodeSignature: true
        )) != nil
      else {
        logger.error("runtime_unavailable component=piAgent reason=integrity_check_failed")
        return nil
      }
    }
    let piAgentDirectory: URL
    if let override = developerOverride(named: "MIEN_PI_AGENT_DIR") {
      piAgentDirectory = override
    } else {
      piAgentDirectory =
        applicationSupportURL
        .appendingPathComponent("AgentRuntime", isDirectory: true)
        .appendingPathComponent("PiAgent", isDirectory: true)
      guard
        (try? FileManager.default.createDirectory(
          at: piAgentDirectory,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )) != nil
      else {
        return nil
      }
      do {
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        let bootstrap = CodexCredentialBootstrap()
        _ = try? bootstrap.prepare(
          sourceHome: userHome.appendingPathComponent(".pi/agent", isDirectory: true),
          destinationHome: piAgentDirectory
        )
        let importer = PiCodexCredentialImporter()
        if try !importer.validate(piHome: piAgentDirectory) {
          let result = try importer.prepare(
            codexHome: userHome.appendingPathComponent(".codex", isDirectory: true),
            piHome: piAgentDirectory
          )
          if result == .sourceUnavailable {
            agentUnavailableStatus = "需要连接 Codex 订阅"
            return nil
          }
        }
      } catch {
        logger.error("runtime_unavailable component=piAgent reason=credential_preparation_failed")
        agentUnavailableStatus = "Codex 订阅信息不可用"
        return nil
      }
    }
    let taskRoot = applicationSupportURL.appendingPathComponent("Tasks", isDirectory: true)
    guard
      (try? FileManager.default.createDirectory(
        at: taskRoot,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )) != nil
    else {
      return nil
    }
    let process = ACPProcessConfiguration(
      executableURL: agentURL,
      workingDirectoryURL: taskRoot,
      environment: [
        "PATH": "\(helperDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin",
        "PI_AGENT_DIR": piAgentDirectory.path,
      ],
      expectedExecutableSHA256: digests?.piAgent
    )
    guard
      let configuration = try? PiAgentBridgeConfiguration(
        process: process,
        clientInfo: ACPImplementation(
          name: "mien",
          title: "Mien",
          version: "0.1.0"
        )
      )
    else {
      return nil
    }
    return PiAgentBridge(configuration: configuration)
  }

  func makeLoginCoordinator() throws -> CodexDeviceLoginCoordinator? {
    let supportURL = try applicationSupportDirectory()
    let helperDirectory =
      bundleURL
      .appendingPathComponent("Contents/Helpers", isDirectory: true)
    let agentOverride = developerOverride(named: "MIEN_PI_AGENT_PATH")
    let agentURL = agentOverride ?? helperDirectory.appendingPathComponent("mien-pi-agent")
    guard FileManager.default.isExecutableFile(atPath: agentURL.path) else { return nil }
    if agentOverride == nil {
      guard let digest = runtimeDigests()?.piAgent,
        (try? ExecutableIntegrity.verify(
          agentURL,
          expectedSHA256: digest,
          requireValidCodeSignature: true
        )) != nil
      else { return nil }
    }
    let piAgentDirectory =
      supportURL
      .appendingPathComponent("AgentRuntime", isDirectory: true)
      .appendingPathComponent("PiAgent", isDirectory: true)
    let taskRoot = supportURL.appendingPathComponent("Tasks", isDirectory: true)
    try FileManager.default.createDirectory(
      at: taskRoot,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let configuration = try CodexDeviceLoginConfiguration(
      executableURL: agentURL,
      codexHomeURL: piAgentDirectory,
      workingDirectoryURL: taskRoot,
      environment: [
        "PATH": "\(helperDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": NSTemporaryDirectory(),
        "LANG": "en_US.UTF-8",
      ]
    )
    return CodexDeviceLoginCoordinator(configuration: configuration)
  }

  private func makeLongviewProvider(
    applicationSupportURL: URL,
    store: PrivateArtifactStore
  ) -> LongviewContextProvider? {
    let helperDirectory =
      bundleURL
      .appendingPathComponent("Contents/Helpers", isDirectory: true)
    let override = developerOverride(named: "CONTEXTUAL_ACTION_LONGVIEW_PATH")
    let executableURL =
      override
      ?? helperDirectory.appendingPathComponent("longview")
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
      logger.error("runtime_unavailable component=longview reason=missing_executable")
      return nil
    }
    if override == nil {
      guard let digest = runtimeDigests()?.longview,
        (try? ExecutableIntegrity.verify(
          executableURL,
          expectedSHA256: digest,
          requireValidCodeSignature: true
        )) != nil
      else {
        logger.error("runtime_unavailable component=longview reason=integrity_check_failed")
        return nil
      }
    }
    let temporaryRoot =
      applicationSupportURL
      .appendingPathComponent("Temporary", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: temporaryRoot,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    return try? LongviewContextProvider(
      executableURL: executableURL,
      store: store,
      temporaryRoot: temporaryRoot
    )
  }

  private func developerOverride(named name: String) -> URL? {
    #if DEBUG
      return environment[name].map(URL.init(fileURLWithPath:))
    #else
      return nil
    #endif
  }

  private func runtimeDigests() -> RuntimeDigests? {
    guard
      let url = resourceURL?.appendingPathComponent("runtime-digests.json"),
      let data = try? Data(contentsOf: url)
    else {
      return nil
    }
    return try? JSONDecoder().decode(RuntimeDigests.self, from: data)
  }
}
