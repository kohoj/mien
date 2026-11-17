# Distribution and runtime integrity

## User experience

The intended consumer install is one notarized universal macOS app. The user drags it to Applications, opens it once, and completes one native readiness surface: connect the bundled Pi Agent to a Codex subscription, allow at least one sensing route, then use the global shortcut. Missing credentials use Pi's official OpenAI device-code OAuth flow and Mien verifies the bounded Agent handshake. Permission state comes only from Apple's public preflight APIs. A pane-attached guide handles missing TCC rows, while the signed Host remains the only TCC identity. A granted capability is used only when the Agent explicitly requests its evidence class and Host policy allows it. No Homebrew, Node, Bun, Python, terminal command, or separate Longview install is part of the consumer path.

The repository currently proves a universal `arm64 + x86_64`, ad-hoc-signed development bundle and deterministic rendering of the native onboarding surface. It does not yet prove Developer ID signing, notarization, or a complete clean-account TCC pass.

Git clone remains a first-class contributor path, not the default consumer experience.

For local contributor builds, `script/build_and_run.sh` is the single build,
install, and launch entrypoint. It delegates to the canonical assembly and
installation scripts below and supports `--debug`, `--logs`, `--telemetry`, and
`--verify`; `.codex/environments/environment.toml` wires the same path to the
Codex Run action.

## Bundle layout

```text
Mien.app/
  Contents/MacOS/Mien
  Contents/Helpers/mien-pi-agent
  Contents/Helpers/longview
  Contents/Resources/Mien.icns
  Contents/Resources/runtime-manifest.json
  Contents/Resources/runtime-digests.json
  Contents/Resources/ResultRenderer/{index.html,renderer.js,styles.css}
  Contents/Resources/result-renderer-components.json
  Contents/Resources/mien.cdx.json
  Contents/Resources/ThirdPartyLicenses/
```

With no helper arguments, `scripts/assemble-app.sh` delegates to `scripts/prepare-runtime-helpers.sh`. That script reads the pinned manifest, checks out exact Pi and Longview commits, builds the Mien Pi wrapper and Longview for both Darwin architectures, merges universal executables, and records source/provenance digests, including the account-catalog adapter and turn protocol. It ad-hoc signs and verifies the merged Pi helper before executing its version probe, because universal assembly invalidates Bun's embedded linker signature. The assembler also accepts two explicit helper paths for controlled development. It checks that every helper covers the requested architecture set, requires the locally generated Streamdown result renderer to match its exact npm lock and Bun 1.3.13 output, builds Mien, embeds the offline renderer plus a transitive component/license manifest, signs nested code from the inside out, records post-sign SHA-256 digests, signs the app with Hardened Runtime, and verifies the bundle. Node, npm, Bun, and the installed Streamdown skill are build-time inputs only; none is invoked by the consumer app.

`scripts/notarize-release.sh` accepts only a Developer ID-signed app and a `notarytool` keychain profile. It submits a temporary archive, waits for Apple, staples and validates the ticket, runs Gatekeeper assessment, re-verifies every nested signature and digest, then emits the distributable zip and SHA-256 file. Credentials never appear in command arguments or repository files.

Build and preview scripts locate Swift products through `swift build --show-bin-path` with the same package, scratch path, configuration, and architecture used for compilation. They never infer a toolchain-specific output directory or reuse a leftover product from an earlier build layout.

## Trust rules

- Production never runs `npx`, a shell launcher, or an arbitrary binary found on `PATH`.
- The result WebView loads only checked-in bundle resources under a deny-by-default Content Security Policy. It has a nonpersistent data store, no renderer network or remote-image path, no raw HTML, no popup path, and no navigation path other than an explicit user-activated `https` or `mailto` handoff to macOS.
- Mien checks the runtime manifest, executable identity, architecture, and signature before launch.
- Pi Agent inherits only a narrow environment and a private credential directory. Mien may import an existing owner-only Pi credential or schema-convert an existing owner-only Codex CLI ChatGPT credential; no config, history, MCP, skill, or ambient runtime state is inherited.
- The compiled helper must execute a real Codex OAuth-backed Pi tool loop, not only complete an ACP handshake. This catches missing standalone OAuth modules before packaging.
- Pi receives no Accessibility or Screen Recording handles and has no built-in shell or filesystem tools. Longview receives only an exact, expiring target and bounded capture policy.
- A helper mismatch disables that capability without terminating Mien.

## Signing and cost

Local development and source builds are free. Public frictionless distribution requires Apple Developer Program membership, which is a paid annual membership; verify the current regional price with Apple before enrollment. Code signing, Hardened Runtime, notarization, and stapling do not add a per-build Apple fee beyond membership.

## Release gates

1. Deterministic source revisions, dependency audit, and locked Streamdown renderer regeneration check.
2. Unit, contract, integration, cancellation, and live Pi Agent smoke tests.
3. Universal release build with no private frameworks.
4. Nested signature and digest verification.
5. Notarization and Gatekeeper verification on a clean account.
6. Permission onboarding, reduced-motion, VoiceOver, multi-display, Space, lock/unlock, crash, and upgrade tests.
7. GitHub release containing the notarized archive, checksums, SBOM, changelog, and reproducible source instructions.

## Release commands

```bash
scripts/assemble-app.sh \
  --architectures arm64,x86_64 \
  --identity "Developer ID Application: Example (TEAMID)"

scripts/notarize-release.sh \
  --app "$PWD/.build/distribution/Mien.app" \
  --keychain-profile mien-notary
```

The keychain profile is created once with `xcrun notarytool store-credentials`; release scripts never accept an Apple password or API private key directly.
