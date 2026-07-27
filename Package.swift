// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "MienWorkspace",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "MienContracts", targets: ["MienContracts"]),
    .library(name: "SubprocessKernel", targets: ["SubprocessKernel"]),
    .library(name: "PermissionKernel", targets: ["PermissionKernel"]),
    .library(name: "InvocationKernel", targets: ["InvocationKernel"]),
    .library(name: "ContextKernel", targets: ["ContextKernel"]),
    .library(name: "PolicyKernel", targets: ["PolicyKernel"]),
    .library(name: "TaskRuntime", targets: ["TaskRuntime"]),
    .library(name: "ProviderAdapters", targets: ["ProviderAdapters"]),
    .library(name: "ACPGateway", targets: ["ACPGateway"]),
    .library(name: "InteractionShell", targets: ["InteractionShell"]),
    .library(name: "ArtifactStore", targets: ["ArtifactStore"]),
    .library(name: "ActionKernel", targets: ["ActionKernel"]),
    .library(name: "DesktopActionAdapters", targets: ["DesktopActionAdapters"]),
    .library(name: "MemoryKernel", targets: ["MemoryKernel"]),
    .library(name: "HostRuntime", targets: ["HostRuntime"]),
    .executable(name: "mien", targets: ["Mien"]),
    .executable(name: "mien-preview", targets: ["MienPreview"]),
  ],
  targets: [
    .target(name: "MienContracts"),
    .target(name: "SubprocessKernel"),
    .target(
      name: "PermissionKernel",
      linkerSettings: [
        .linkedFramework("ApplicationServices"),
        .linkedFramework("CoreGraphics"),
      ]
    ),
    .target(
      name: "InvocationKernel",
      dependencies: ["MienContracts"],
      linkerSettings: [
        .linkedFramework("ApplicationServices"),
        .linkedFramework("AppKit"),
        .linkedFramework("CoreGraphics"),
      ]
    ),
    .target(
      name: "ContextKernel",
      dependencies: ["MienContracts"]
    ),
    .target(
      name: "PolicyKernel",
      dependencies: ["MienContracts"]
    ),
    .target(
      name: "TaskRuntime",
      dependencies: ["MienContracts"]
    ),
    .target(
      name: "ProviderAdapters",
      dependencies: [
        "ArtifactStore",
        "ContextKernel",
        "MienContracts",
        "SubprocessKernel",
      ],
      linkerSettings: [
        .linkedFramework("ApplicationServices"),
        .linkedFramework("AppKit"),
      ]
    ),
    .target(
      name: "ACPGateway",
      dependencies: ["MienContracts", "SubprocessKernel"],
      linkerSettings: [
        .linkedFramework("Security")
      ]
    ),
    .target(
      name: "InteractionShell",
      dependencies: ["MienContracts", "InvocationKernel"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("Carbon"),
      ]
    ),
    .target(
      name: "ArtifactStore",
      dependencies: ["MienContracts"]
    ),
    .target(
      name: "ActionKernel",
      dependencies: ["MienContracts", "PolicyKernel"]
    ),
    .target(
      name: "DesktopActionAdapters",
      dependencies: ["ActionKernel", "MienContracts"],
      linkerSettings: [
        .linkedFramework("ApplicationServices"),
        .linkedFramework("AppKit"),
      ]
    ),
    .target(
      name: "MemoryKernel",
      dependencies: ["MienContracts"]
    ),
    .target(
      name: "HostRuntime",
      dependencies: [
        "ACPGateway",
        "MienContracts",
        "ContextKernel",
        "PolicyKernel",
        "TaskRuntime",
        "ActionKernel",
        "DesktopActionAdapters",
        "MemoryKernel",
        "SubprocessKernel",
      ]
    ),
    .executableTarget(
      name: "Mien",
      dependencies: [
        "MienContracts",
        "InvocationKernel",
        "InteractionShell",
        "ContextKernel",
        "PolicyKernel",
        "TaskRuntime",
        "ProviderAdapters",
        "ACPGateway",
        "ArtifactStore",
        "ActionKernel",
        "MemoryKernel",
        "PermissionKernel",
        "HostRuntime",
      ],
      linkerSettings: [
        .linkedFramework("AppKit")
      ]
    ),
    .executableTarget(
      name: "MienPreview",
      dependencies: ["InteractionShell"],
      linkerSettings: [
        .linkedFramework("AppKit")
      ]
    ),
    .testTarget(
      name: "MienContractsTests",
      dependencies: ["MienContracts"]
    ),
    .testTarget(
      name: "InvocationKernelTests",
      dependencies: ["InvocationKernel", "MienContracts"]
    ),
    .testTarget(
      name: "ContextKernelTests",
      dependencies: ["ContextKernel", "MienContracts"]
    ),
    .testTarget(
      name: "PolicyKernelTests",
      dependencies: ["PolicyKernel", "MienContracts"]
    ),
    .testTarget(
      name: "TaskRuntimeTests",
      dependencies: ["TaskRuntime", "MienContracts"]
    ),
    .testTarget(
      name: "ProviderAdaptersTests",
      dependencies: [
        "ArtifactStore",
        "ContextKernel",
        "ProviderAdapters",
        "MienContracts",
      ]
    ),
    .testTarget(
      name: "ACPGatewayTests",
      dependencies: ["ACPGateway", "MienContracts"]
    ),
    .testTarget(
      name: "InteractionShellTests",
      dependencies: ["InteractionShell", "MienContracts"]
    ),
    .testTarget(
      name: "ArtifactStoreTests",
      dependencies: ["ArtifactStore", "MienContracts"]
    ),
    .testTarget(
      name: "ActionKernelTests",
      dependencies: ["ActionKernel", "MienContracts", "PolicyKernel"]
    ),
    .testTarget(
      name: "DesktopActionAdaptersTests",
      dependencies: [
        "ActionKernel",
        "MienContracts",
        "DesktopActionAdapters",
      ]
    ),
    .testTarget(
      name: "MemoryKernelTests",
      dependencies: ["MemoryKernel", "MienContracts"]
    ),
    .testTarget(
      name: "HostRuntimeTests",
      dependencies: [
        "ACPGateway",
        "HostRuntime",
        "ContextKernel",
        "MienContracts",
        "TaskRuntime",
      ]
    ),
  ]
)
