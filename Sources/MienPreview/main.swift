import AppKit
import Darwin
import Foundation
import InteractionShell

@main
@MainActor
private enum MienPreviewMain {
  static func main() {
    do {
      try run()
    } catch {
      FileHandle.standardError.write(Data("preview failed: \(error)\n".utf8))
      Darwin.exit(1)
    }
  }

  private static func run() throws {
    _ = NSApplication.shared
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 2 else {
      FileHandle.standardError.write(
        Data(
          "usage: mien-preview STATE OUTPUT.png | --all|--all-dark DIRECTORY\n"
            .utf8
        )
      )
      Darwin.exit(64)
    }
    if arguments[0] == "--all" || arguments[0] == "--all-dark" {
      try renderAll(
        to: URL(fileURLWithPath: arguments[1]).standardizedFileURL,
        appearance: arguments[0] == "--all-dark" ? .darkAqua : .aqua)
      return
    }
    if let readinessState = ReadinessPreviewState(rawValue: arguments[0]) {
      let output = URL(fileURLWithPath: arguments[1]).standardizedFileURL
      guard output.path.hasPrefix("/"), output.pathExtension.lowercased() == "png" else {
        throw CocoaError(.fileWriteInvalidFileName)
      }
      try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try ReadinessPreviewRenderer.png(state: readinessState).write(to: output, options: .atomic)
      print(output.path)
      return
    }
    if arguments[0] == "permission-guide" {
      let output = URL(fileURLWithPath: arguments[1]).standardizedFileURL
      guard output.path.hasPrefix("/"), output.pathExtension.lowercased() == "png" else {
        throw CocoaError(.fileWriteInvalidFileName)
      }
      try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try PermissionGuidePreviewRenderer.png().write(to: output, options: .atomic)
      print(output.path)
      return
    }
    guard let state = OverlayPreviewState(rawValue: arguments[0]) else { Darwin.exit(64) }
    let output = URL(fileURLWithPath: arguments[1]).standardizedFileURL
    guard output.path.hasPrefix("/"), output.pathExtension.lowercased() == "png" else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try OverlayPreviewRenderer.png(state: state).write(to: output, options: .atomic)
    print(output.path)
  }

  private static func renderAll(to directory: URL, appearance: NSAppearance.Name) throws {
    guard directory.path.hasPrefix("/") else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    for state in OverlayPreviewState.allCases {
      let output = directory.appendingPathComponent("\(state.rawValue).png")
      try OverlayPreviewRenderer.png(state: state, appearance: appearance).write(
        to: output, options: .atomic)
      print(output.path)
    }
    for state in ReadinessPreviewState.allCases {
      let output = directory.appendingPathComponent("\(state.rawValue).png")
      try ReadinessPreviewRenderer.png(state: state, appearance: appearance).write(
        to: output, options: .atomic)
      print(output.path)
    }
    let permissionGuide = directory.appendingPathComponent("permission-guide.png")
    try PermissionGuidePreviewRenderer.png(appearance: appearance).write(
      to: permissionGuide, options: .atomic)
    print(permissionGuide.path)
  }
}
