# Distribution and runtime integrity

## User experience

The intended consumer install is one notarized universal macOS app. The user drags it to Applications, opens it once, reuses an existing private Codex login or completes first-run device login, grants Accessibility and Screen Recording only when a requested capability needs them, and then uses the global shortcut. No Homebrew, Node, Bun, Python, terminal command, or separate Longview install is part of the consumer path.

The repository currently proves a universal `arm64 + x86_64`, ad-hoc-signed development bundle. It does not yet prove Developer ID signing, notarization, or clean-account permission onboarding.

Git clone remains a first-class contributor path, not the default consumer experience.

## Bundle layout

```text
Mien.app/
  Contents/MacOS/Mien
  Contents/Helpers/codex-acp
  Contents/Helpers/codex
  Contents/Helpers/longview
  Contents/Resources/Mien.icns
  Contents/Resources/runtime-manifest.json
  Contents/Resources/runtime-digests.json
  Contents/Resources/mien.cdx.json
  Contents/Resources/ThirdPartyLicenses/
```

With no helper arguments, `scripts/assemble-app.sh` delegates to `scripts/prepare-runtime-helpers.sh`. That script reads the pinned manifest, obtains the exact official Codex packages, checks out exact `codex-acp` and Longview commits, builds both Darwin architectures, merges universal executables, and records provenance and digests. The assembler also accepts three explicit helper paths for controlled development. It checks that every helper covers the requested architecture set, builds Mien, signs nested code from the inside out, records post-sign SHA-256 digests, signs the app with Hardened Runtime, and verifies the bundle.

`scripts/notarize-release.sh` accepts only a Developer ID-signed app and a `notarytool` keychain profile. It submits a temporary archive, waits for Apple, staples and validates the ticket, runs Gatekeeper assessment, re-verifies every nested signature and digest, then emits the distributable zip and SHA-256 file. Credentials never appear in command arguments or repository files.

## Trust rules

- Production never runs `npx`, a shell launcher, or an arbitrary binary found on `PATH`.
- Mien checks the runtime manifest, executable identity, architecture, and signature before launch.
- `codex-acp` and Codex inherit only a narrow environment. `APP_SERVER_LOGS` is forbidden.
- ACP receives no Accessibility or Screen Recording handles. Longview receives only an exact, expiring target and bounded capture policy.
- A helper mismatch disables that capability without terminating Mien.

## Signing and cost

Local development and source builds are free. Public frictionless distribution requires Apple Developer Program membership, which is a paid annual membership; verify the current regional price with Apple before enrollment. Code signing, Hardened Runtime, notarization, and stapling do not add a per-build Apple fee beyond membership.

## Release gates

1. Deterministic source revisions and dependency audit.
2. Unit, contract, integration, cancellation, and live ACP smoke tests.
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
