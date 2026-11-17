# Release status

Updated: 2026-07-29

This file separates implemented behavior from the intended product contract. A checked item means there is current code and proportionate automated or live evidence; it does not substitute for the remaining manual release gates.

## Works now

- One global shortcut freezes the pointed app, exact WindowServer window, semantic element, focus, selection, pointer, display, and input epoch before the overlay appears.
- User input is sent verbatim once to one conversation-bound Pi Agent session. During that same turn, Pi selects one exact typed evidence request through `request_context`, consumes the Host-verified result, and closes through `submit_outcome`; Host code contains no intent keywords, scope classifier, prose parser, or second planning prompt.
- First launch presents one native readiness surface for Agent handshake, device authentication, live Codex model selection, Accessibility, and Screen Recording. The same surface is Mien Settings from the menu bar. Typed System Settings routes, a pane-attached draggable app guide, foreground refresh, and menu-bar re-entry prevent late dead ends; persisted UI state never overrides live Agent or TCC truth.
- Context acquisition can satisfy Agent-requested multimodal bundles, including Accessibility with one current frame or bounded visual history. Deterministic Host policy, budgets, target lineage, and restoration verification remain mandatory.
- Every context result is private, immutable, digest-verified, budgeted, target-scoped, and deleted after the task by default.
- The overlay states both the semantic scope and whether each distinct source will be sent to the Agent or kept on the Mac.
- Pi runs as one pinned bundled helper behind a bounded request transport with output caps, deadlines, cancellation, session close, and restart containment. Its default filesystem, shell, extension, skill, prompt, and context-file surfaces are disabled; only `request_context` and `submit_outcome` are installed.
- The packaged Pi version and commit must exactly match the runtime manifest. The universal helper is built for arm64 and x86_64 and verified after signing.
- The runtime owns a private Pi Agent directory. Existing Pi users get a one-time owner-only credential copy; existing Codex CLI users get a narrow schema conversion after account-claim validation. No configuration or history is inherited. Users without credentials get Pi's OpenAI Codex subscription device-login URL and code inside the native flow, and the original task resumes after authentication.
- A generated draft may be inserted only into the exact editable Accessibility element after a fresh target rebind and compare-and-swap precondition. Mien reads the value back, automatically rolls back an unverified write, never sends, and offers bounded undo that refuses to overwrite later user input.
- Task truth is an fsynced private segmented journal. Closed segments are immutable; startup validates sequence continuity, quarantines only a torn active tail, removes interrupted private residue, and never records cleanup success when desktop restoration is unknown.
- Once context acquisition and desktop restoration are safe, a running task can detach to one menu-bar task center and restore without losing its target or result.
- Validated terminal Agent results render through a pinned offline Streamdown document surface with CJK-aware Markdown, strict HTML/URL/resource denial, semantic macOS colors, selectable content, bounded height reporting, and AppKit-owned lifecycle and controls.
- The universal development app is assembled inside-out, Hardened Runtime signed ad hoc, architecture-checked, nested-signature checked, and post-sign digest checked.
- Deterministic local previews cover onboarding, compose, Streamdown-rendered results, login, draft insertion, and undo. Side-by-side comparison with the visual target caught and closed the missing mouse-submit path, variable-width status layout, and a WebView height-propagation defect that clipped wrapped results.

## Not yet a notarized consumer release

- It is ad-hoc signed. Developer ID signing, Apple notarization, stapling, and Gatekeeper proof require the publisher's Apple Developer credentials.
- Private-browser and sensitive-content detection cannot be proven from window metadata alone; those surfaces remain a fail-closed support gap.
- VoiceOver, Full Keyboard Access, fresh-account TCC, Reduce Transparency, multi-display/Spaces, sleep/wake, upgrade, and uninstall need manual clean-machine evidence.
- Performance percentiles and the 24-hour / 10,000-task soak have not been run.
- Live provider availability and long-duration Pi tool-loop stability remain release gates. Mien fails connection and turn deadlines visibly and offers retry; the availability target is not yet proven.
- The deterministic preview is not a substitute for a complete native-window visual and assistive-technology pass on a clean Mac.

## Current evidence

| Area | Evidence |
|---|---|
| Swift contracts and modules | 157 tests, 2 opt-in live tests skipped during the normal suite, zero failures |
| Result renderer | 4 static Streamdown Markdown/CJK/structure/security tests, offline CSP resource test, exact generated-artifact check, npm production audit with zero known vulnerabilities |
| Process cancellation | stubborn child receives TERM then process-group KILL within the bounded fence |
| Packaged ACP | the installed universal Pi Agent handshake passed in 0.233 seconds; a real two-turn Codex-subscription conversation selected an explicit live model, called `request_context` / `submit_outcome`, then restored the Agent default before the follow-up in 10.563 seconds |
| Intel runtime | x86_64 Pi Agent and Longview probes plus a real ACP handshake under Rosetta passed |
| App integrity | universal host and helpers, strict nested codesign verification, manifest digest recomputation |
| Release automation | pinned helper reconstruction, production dependency audit, source verification, exact Pi version gate, locked local Streamdown regeneration gate, universal-input gate, inside-out signing, CycloneDX SBOM with 102 renderer components, complete embedded licenses, notarization/stapling/Gatekeeper script |

## Release definition

The first frictionless consumer download is ready only when the remaining items above are either completed or explicitly removed from the supported product surface. An ad-hoc developer preview, unit test, screenshot, or local fixture is never described as notarized or generally available proof.
