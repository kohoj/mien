# Release status

Updated: 2026-07-27

This file separates implemented behavior from the intended product contract. A checked item means there is current code and proportionate automated or live evidence; it does not substitute for the remaining manual release gates.

## Works now

- One global shortcut freezes the pointed app, exact WindowServer window, semantic element, focus, selection, pointer, display, and input epoch before the overlay appears.
- Deterministic policy runs before Accessibility traversal or pixel capture. Accessibility and Screen Recording are requested only when the requested scope needs them.
- Context acquisition uses the minimum provider ladder: selection, Accessibility, then background-only Longview for bounded history.
- Every context result is private, immutable, digest-verified, budgeted, target-scoped, and deleted after the task by default.
- The overlay states both the semantic scope and whether each distinct source will be sent to Codex or kept on the Mac.
- Codex runs through pinned ACP v1 in a bounded process group with output caps, deadlines, cancellation, session close, and restart containment.
- The packaged Codex version must exactly match the runtime manifest. Live arm64 and Intel-under-Rosetta ACP handshakes have passed against the pinned bundle.
- The runtime owns a private Codex home. Existing Codex users get a one-time, owner-only copy of `auth.json`; users without credentials get the official device-login URL and code inside the native flow, and the original task resumes after authentication.
- A generated draft may be inserted only into the exact editable Accessibility element after a fresh target rebind and compare-and-swap precondition. Mien reads the value back, automatically rolls back an unverified write, never sends, and offers bounded undo that refuses to overwrite later user input.
- Task truth is an fsynced private segmented journal. Closed segments are immutable; startup validates sequence continuity, quarantines only a torn active tail, removes interrupted private residue, and never records cleanup success when desktop restoration is unknown.
- Once context acquisition and desktop restoration are safe, a running task can detach to one menu-bar task center and restore without losing its target or result.
- The universal development app is assembled inside-out, Hardened Runtime signed ad hoc, architecture-checked, nested-signature checked, and post-sign digest checked.
- Deterministic native previews cover compose, login, draft insertion, and undo. Side-by-side comparison with the visual target caught and closed the missing mouse-submit path and a variable-width status layout.

## Not yet a notarized consumer release

- It is ad-hoc signed. Developer ID signing, Apple notarization, stapling, and Gatekeeper proof require the publisher's Apple Developer credentials.
- Private-browser and sensitive-content detection cannot be proven from window metadata alone; those surfaces remain a fail-closed support gap.
- VoiceOver, Full Keyboard Access, fresh-account TCC, Reduce Transparency, multi-display/Spaces, sleep/wake, upgrade, and uninstall need manual clean-machine evidence.
- Performance percentiles and the 24-hour / 10,000-task soak have not been run.
- Live provider availability is not yet stable: one packaged turn returned in 6.074 seconds, while a later `session/prompt` reached the task deadline and a direct Codex probe stalled at the same time. Mien fails that state safely and offers retry, but the availability target is not proven.
- The deterministic preview is not a substitute for a complete native-window visual and assistive-technology pass on a clean Mac.

## Current evidence

| Area | Evidence |
|---|---|
| Swift contracts and modules | 72 tests, 2 opt-in live tests skipped during the normal suite, zero failures |
| Process cancellation | stubborn child receives TERM then process-group KILL within the bounded fence |
| Packaged ACP | repeated live handshakes passed; one exact `READY` turn passed in 6.074 seconds; a later provider turn timed out and is retained as negative evidence |
| Intel runtime | x86_64 Codex and Longview probes plus a real ACP handshake under Rosetta passed |
| App integrity | universal host and helpers, strict nested codesign verification, manifest digest recomputation |
| Release automation | pinned helper reconstruction, production dependency audit, source verification, exact Codex version gate, universal-input gate, inside-out signing, CycloneDX SBOM, embedded licenses, notarization/stapling/Gatekeeper script |

## Release definition

The first frictionless consumer download is ready only when the remaining items above are either completed or explicitly removed from the supported product surface. An ad-hoc developer preview, unit test, screenshot, or local fixture is never described as notarized or generally available proof.
