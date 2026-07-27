# Quality and release gates

These are product requirements, not aspirational metrics. A release may narrow its declared support matrix, but it may not silently weaken a gate.

## Reliability

| Gate | Target |
|---|---:|
| Warm ACP runtime availability | at least 99.9% |
| Silent residual desktop mutation | 0 |
| Background-only unexpected activation or pointer movement | 0 |
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

## Interaction

- The overlay never becomes the target of its own invocation.
- The composer moves at most once after first placement.
- The halo does not cover the cursor hotspot or selected text.
- Any state answers: what is targeted, what is included, what is happening, and how to stop.
- Short tasks finish in place; long tasks detach; concurrent tasks share one task center.
- Drafts do not send automatically.

## Accessibility

- The core task matrix completes with keyboard only and with VoiceOver.
- CJK marked text never submits prematurely.
- Reduce Motion removes scaling, springs, and spatial flight.
- Increase Contrast and Reduce Transparency remain legible.
- Status never depends on color or sound alone.
- Multi-display, scaled display, RTL, Full Screen, Spaces, Stage Manager, and screen zoom are in the regression matrix.

## Engineering

- Swift 6 strict concurrency build is clean.
- New modules have one owner and no dependency cycle.
- Contract schema changes require fixtures and compatibility notes.
- Runtime work requires process restart and a live probe; unit tests alone are insufficient.
- Every provider and executor has deterministic failure semantics, cancellation coverage, and bounded resource use.
- Release candidates pass unit, contract, recovery, security, performance, soak, signing, notarization, clean-machine TCC, upgrade, and rollback checks.

## Distribution

- One stable bundle identifier, Team ID, and designated requirement.
- Hardened Runtime and Developer ID signing for the Host and every nested executable.
- Inside-out signing, secure timestamp, notarization, stapling, `codesign --verify --strict`, and `spctl --assess`.
- Clean macOS user verification covers Gatekeeper, just-in-time TCC, login item opt-in, upgrade retention, and uninstall behavior.
- Runtime updates replace a signed artifact atomically; they never mutate executable content inside an installed signed app.
