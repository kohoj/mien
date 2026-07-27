# Contributing

Mien is an MIT-licensed macOS systems project. Small, complete changes with one clear owner are preferred over broad patches.

## Development

Requirements are macOS 14 or newer, Xcode with Swift 6, Git, npm, `jq`, and Bun 1.3.13.

```bash
git clone https://github.com/kohoj/mien.git
cd mien
scripts/verify-mien.sh
```

For runtime or packaging work, also run:

```bash
scripts/assemble-app.sh
scripts/verify-app-bundle.sh "$PWD/.build/distribution/Mien.app"
```

ACP integration tests are deliberately opt-in because they use a real bundled runtime:

```bash
RUN_ACP_LIVE_SMOKE=1 swift test --filter testLiveCodexACPHandshakeWhenExplicitlyEnabled
```

## Design rules

- The signed Host owns target identity, context authorization, policy, mutation, verification, and recovery.
- The model proposes; model text and process status never prove that an action succeeded.
- New capabilities are typed, bounded, exact-target grants. Do not add shell, clipboard, general click/type, or unrestricted AX surfaces.
- Preserve fail-closed behavior, cancellation, resource bounds, and a recovery receipt for every side effect.
- Keep Longview independent and integrate only through its released artifact and receipt schema.
- Update contracts, tests, release status, and user-visible disclosure together.

Open a focused pull request with the motivation, trust-boundary impact, verification performed, and any remaining manual evidence.
