#!/bin/zsh
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"

swift test
swift build -c release --product mien

swift format lint --strict --recursive \
  Sources/ACPGateway \
  Sources/ActionKernel \
  Sources/ArtifactStore \
  Sources/ContextKernel \
  Sources/MienContracts \
  Sources/Mien \
  Sources/MienPreview \
  Sources/DesktopActionAdapters \
  Sources/HostRuntime \
  Sources/InteractionShell \
  Sources/InvocationKernel \
  Sources/MemoryKernel \
  Sources/PermissionKernel \
  Sources/PolicyKernel \
  Sources/ProviderAdapters \
  Sources/SubprocessKernel \
  Sources/TaskRuntime \
  Tests/ACPGatewayTests \
  Tests/ActionKernelTests \
  Tests/ArtifactStoreTests \
  Tests/ContextKernelTests \
  Tests/MienContractsTests \
  Tests/DesktopActionAdaptersTests \
  Tests/HostRuntimeTests \
  Tests/InteractionShellTests \
  Tests/InvocationKernelTests \
  Tests/MemoryKernelTests \
  Tests/PolicyKernelTests \
  Tests/ProviderAdaptersTests \
  Tests/TaskRuntimeTests

jq -e '
  .schemaVersion == 1 and
  .acpProtocolVersion == 1 and
  .buildToolchain.bun == "1.3.13" and
  .codex.version == "0.145.0" and
  .codexACP.version == "1.1.7" and
  (.codex.commit | test("^[0-9a-f]{40}$")) and
  (.codexACP.commit | test("^[0-9a-f]{40}$")) and
  (.longview.commit | test("^[0-9a-f]{40}$"))
' Config/runtime-manifest.json >/dev/null

plutil -lint Config/Info.plist Config/Mien.entitlements >/dev/null
test "$(plutil -extract CFBundleIdentifier raw Config/Info.plist)" = \
  "io.github.kohoj.mien"
test "$(plutil -extract CFBundleExecutable raw Config/Info.plist)" = "Mien"
test "$(plutil -extract CFBundleIconFile raw Config/Info.plist)" = "Mien.icns"
test "$(plutil -extract LSUIElement raw Config/Info.plist)" = "true"
test -s Resources/AppIcon/mien-1024.png
test "$(sips -g pixelWidth Resources/AppIcon/mien-1024.png | awk '/pixelWidth/ { print $2 }')" = \
  "1024"
test "$(sips -g pixelHeight Resources/AppIcon/mien-1024.png | awk '/pixelHeight/ { print $2 }')" = \
  "1024"
test -s THIRD_PARTY_NOTICES.md
for script in scripts/*.sh; do
  zsh -n "$script"
done

preview_root="$(mktemp -d "${TMPDIR:-/tmp}/mien-preview.XXXXXX")"
trap 'rm -rf "$preview_root"' EXIT
swift build -c release --product mien-preview
preview_binary="$repository_root/.build/release/mien-preview"
"$preview_binary" --all "$preview_root"
for state in composing draft undo login; do
  test -s "$preview_root/$state.png"
done

if rg -n 'import (LongviewCore|LongviewCapture|LongviewCLIKit|AmbientContextCore)' \
  Sources/ACPGateway Sources/ActionKernel Sources/ArtifactStore Sources/ContextKernel \
  Sources/MienContracts Sources/Mien Sources/HostRuntime \
  Sources/MienPreview \
  Sources/DesktopActionAdapters \
  Sources/InteractionShell Sources/InvocationKernel Sources/MemoryKernel \
  Sources/PermissionKernel Sources/PolicyKernel Sources/ProviderAdapters \
  Sources/SubprocessKernel Sources/TaskRuntime; then
  print -u2 'Product modules must not import quarantined implementations.'
  exit 1
fi

git diff --check
