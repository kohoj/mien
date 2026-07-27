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
          "usage: mien-preview composing|draft|undo|login OUTPUT.png\n"
            .utf8
        )
      )
      Darwin.exit(64)
    }
    if arguments[0] == "--all" {
      try renderAll(to: URL(fileURLWithPath: arguments[1]).standardizedFileURL)
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

  private static func renderAll(to directory: URL) throws {
    guard directory.path.hasPrefix("/") else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    for state in OverlayPreviewState.allCases {
      let output = directory.appendingPathComponent("\(state.rawValue).png")
      try OverlayPreviewRenderer.png(state: state).write(to: output, options: .atomic)
      print(output.path)
    }
  }
}
