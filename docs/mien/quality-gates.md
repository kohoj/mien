# Quality and release gates

These are product requirements, not aspirational metrics. A release may narrow its declared support matrix, but it may not silently weaken a gate.

## Reliability

| Gate | Target |
|---|---:|
| Warm Pi Agent runtime availability | at least 99.9% |
| Silent residual desktop mutation | 0 |
| Unrestored Longview activation, viewport, focus, or pointer movement | 0 |
| Supported mutation produces verified or failed receipt | 100% |
| Supported restoration verified | at least 99.95% |
| 24-hour / 10,000-task soak orphan or zombie processes | 0 |
| Task failure loses intent or frozen target | 0 |

## Performance

| Gate | Target |
|---|---:|
| Hotkey to halo first frame | p95 50 ms, p99 80 ms |
| Hotkey to composer accepting input | p95 85 ms |
| Coarse window target | p95 45 ms |
| AX semantic refinement | p95 120 ms, hard deadline 180 ms |
| Warm single-window screenshot | p95 300 ms, p99 500 ms |
| Submit acknowledgement | p95 120 ms |
| Cancel acknowledgement | 100 ms |
| Idle Host CPU | below 0.2% |
| Idle complete runtime CPU | below 0.5% |
| Idle Host RSS | below 90 MB |
| Main-thread stall above one 60 Hz frame | zero at p99.9 |

## Security and privacy

- Every transmitted artifact appears in the user-visible manifest.
- Password, authentication, financial, health, and protected-content policy tests fail closed.
- External commit, destructive action, and persistent memory require approval provenance.
- Prompt injection fixtures cannot widen target, scope, destination, lifetime, or capability.
- Raw artifacts are private, symlink-safe, atomically written, TTL-bound, and deleted after task by default.
- Sensitive logs remain off; secrets never enter receipts, crash reports, or diagnostics.
- The result renderer loads no remote subresource, accepts no raw HTML, exposes no generic script bridge, and permits only user-activated `https` or `mailto` links outside the WebView.

## Interaction

- The overlay never becomes the target of its own invocation.
- The composer moves at most once after first placement.
- The halo does not cover the cursor hotspot or selected text.
- Any state answers: what is targeted, what is included, what is happening, and how to stop.
- Short tasks finish in place; long tasks detach; concurrent tasks share one task center.
- Drafts do not send automatically.
- First use exposes one required next action. An authorized reading route is sufficient; optional capture is not presented as mandatory setup.
- Ordinary menu-bar activation exposes invocation, Settings, and Quit. Command–Comma works in setup, settings, and the nonactivating conversation panel. A retained conversation must not be labelled as a fresh target.
- Command–W closes setup/settings using native window commands and enters the normal task cancellation/cleanup path in the conversation panel.
- Copy and process disclosure are discoverable without a context menu. Failed target resolution explains a next step instead of sounding a beep without UI.
- Account reconnection with an unchanged model catalog restores picker interaction. Missing selected models still block the next task and never silently fall back.

## Accessibility

- The core task matrix completes with keyboard only and with VoiceOver.
- CJK marked text never submits prematurely.
- CJK-adjacent Markdown emphasis renders semantically without exposing delimiter syntax; WebKit document semantics remain usable with VoiceOver and text selection.
- Reduce Motion removes scaling, springs, and spatial flight.
- Increase Contrast and Reduce Transparency remain legible.
- Status never depends on color or sound alone.
- Multi-display, scaled display, RTL, Full Screen, Spaces, Stage Manager, and screen zoom are in the regression matrix.

## Engineering

- Swift 6 strict concurrency build is clean.
- The pinned local Streamdown build, static Markdown/security tests, generated artifacts, CSP, complete transitive renderer licenses, and CycloneDX entries are current.
- New modules have one owner and no dependency cycle.
- Native previews exercise composition, conversation, draft, undo, login, failure, setup connection, permission, browser authorization, model failure, ready state, Settings, and the permission guide in light and dark appearances. Fixtures are visual evidence, not live-task acceptance.
- Contract schema changes require fixtures and compatibility notes.
- Runtime work requires process restart and a live probe; unit tests alone are insufficient.
- A compiled Pi runtime change must pass the live ACP handshake plus OAuth-backed evidence and no-context turns. Both must prove the provider-enforced `request_context` -> `submit_outcome` order through standardized tool activity.
- The opt-in probe uses `RUN_PI_AGENT_LIVE_PROMPT=1`, `PI_AGENT_EXECUTABLE`, an isolated `PI_AGENT_DIR` with valid private OAuth credentials, and `PI_AGENT_ALTERNATE_MODEL_ID` for a second model the account can call. The default comes from the live account catalog. The probe must verify discovery, call a newly advertised model absent from the bundled Pi registry, and switch back to the server default in the same conversation. A registry entry alone does not prove entitlement; no probe may silently switch after provider refusal. Catalog tests cover changed server priority, hidden entries, duplicate/invalid metadata, authentication/HTTP/transport failures, byte bounds, and remote policy exclusion.
- Device-login changes also run `RUN_PI_AGENT_LIVE_LOGIN=1` with `PI_AGENT_EXECUTABLE`: the real bundled helper must publish authorization details through the App's coordinator while it is still awaiting browser approval. The probe cancels before authorization in a temporary credential home. Regression fixtures cover completed login and cancellation; interaction tests cover resuming an immutable turn with renewed target authority after its original lease expires.
- Every provider and executor has deterministic failure semantics, cancellation coverage, and bounded resource use.
- Long-conversation probes verify that offscreen table rows release WebKit resources, revisiting restores exact Markdown and disclosure state, and reset releases visible renderers. The input stays accessible while history scrolls.
- Startup probes distinguish interface registration, recovered Host readiness and network Agent readiness. Runtime hashing/recovery cannot occupy MainActor. Corrupt durable journals fail closed. Cold and warm launch results must be labelled separately.
- Cancelling/replacing a turn must await its settlement and required cleanup before another turn starts; shutdown drains startup, connection and conversation work. Pi releases completed context payloads while retaining dialogue, and a live follow-up must recall prior typed answers without reusing raw target evidence.
- Release candidates pass unit, contract, recovery, security, performance, soak, signing, notarization, clean-machine TCC, upgrade, and rollback checks.

## Distribution

- One stable bundle identifier, Team ID, and designated requirement.
- Hardened Runtime and Developer ID signing for the Host and every nested executable.
- Inside-out signing, secure timestamp, notarization, stapling, `codesign --verify --strict`, and `spctl --assess`.
- Clean macOS user verification covers Gatekeeper, just-in-time TCC, login item opt-in, upgrade retention, and uninstall behavior.
- Runtime updates replace a signed artifact atomically; they never mutate executable content inside an installed signed app.
