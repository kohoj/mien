# Native lifecycle and long-conversation quality pass — 2026-11-17

This follows the first [interaction quality pass](quality-pass-2026-11-17.md).
The implementation follows AppKit's ownership boundaries rather than extending the previous all-views-retained conversation stack.

## Decisions and observed failure paths

- The old `NSStackView` retained every turn and every completed answer's `WKWebView`. A rendered 24-turn workload retained 24 WebViews and 814 descendant views. `ConversationTurn` now stores conversation data independently; `ConversationTranscriptView` uses a view-based `NSTableView` and its native reuse queue. Offscreen cells explicitly release navigation, delegates, script handlers and WebKit resources. A 60-turn regression verifies bounded visible WebViews, exact Markdown reconstruction, and complete release on reset. Lightweight AppKit views may survive briefly during animations; they must not retain offscreen WebKit resources.
- The input was inside the scrolling document. It is now pinned below history, with native NSTextView marked-text handling and internal growth/scrolling preserved. Scroll position is anchored during height changes; cached measured answer heights prevent old rows shrinking while their renderer reloads. Transcript generation and row identity reject late renderer callbacks after reset or reuse. Historical action controls cannot apply to a new task.
- AppDelegate performed synchronous helper integrity checks before installing the interface. `MienRuntimeBootstrap` now owns filesystem preparation, journal recovery, credential preparation and executable verification on an actor executor. AppKit installs the interface with checking readiness first; recovery and live Agent/model readiness still gate task submission. Integrity and recovery were not bypassed or replaced with cached success.
- The old dismissal launched untracked conversation teardown, while subsequent submissions could race it. `ConversationWorkQueue` now owns serial execution and cleanup. Cancelling/replacing execution does not cancel cleanup; subsequent work and app termination await it. Application-owned startup, login and model-discovery tasks are also cancelled and awaited, with post-await cancellation checks preventing late readiness presentation during exit.
- Pi retained each `request_context` response, including captured text and base64 images, for the whole conversation. After a prompt settles, the Agent runtime replaces only those payloads with explicit released-evidence receipts. User and assistant messages, submitted outcomes and tool-call/result identity stay intact. The Agent is informed of this lifetime policy and must request fresh evidence when a later turn needs target details. Failed prompts use the same release path. No Host semantic classification, summarization or dialogue truncation was introduced.

## Ownership

- `AppDelegate`: 32-line AppKit lifecycle adapter.
- `MienApplicationController`: application startup/shutdown, connection/login, model discovery, UI wiring.
- `MienRuntimeBootstrap`: preparation and recovery I/O; returns a Sendable prepared runtime.
- `MienConversationController`: one visible conversation's task/context/outcome/draft/undo lifecycle.
- `ConversationWorkQueue`: execution cancellation, ordering and awaited cleanup, independent of AppKit.
- `ConversationTurn`: immutable submitted text and lightweight display state; table cells are projections.

The signed Host remains the sole owner of target authority, policy, desktop mechanisms and verification. The Pi child still exposes only the two typed tools.

## Measurements

Local workload evidence is in `.build/native-quality/` (not committed artifacts):

| Probe | Previous boundary | New boundary |
|---|---:|---:|
| 24 rendered turns, retained WebViews | 24 | 2 |
| Same workload, descendant NSViews | 814 | 93 |
| Two installed helper integrity checks on MainActor | 103.7 ms continuous work | Runs on bootstrap actor |
| MainActor 5 ms heartbeat during bootstrap | No yielding in the old synchronous integrity section | 6.3 ms maximum observed gap; 15 beats during 93.4 ms preparation |

These are structural resource counts and one local latency sample, not whole-app RSS savings, latency percentiles, or an OS-cold-boot benchmark. The installed helpers and disk caches were warm. Process launch, host preparation, and network-backed Agent readiness are separately logged as `interface_ready`, `runtime_prepared`, `host_ready`, and `agent_ready`; interface registration is not a first-frame measurement.

The raw evidence regression uses a 4 MiB image and captured text: the completed context payload becomes a receipt smaller than 600 bytes, without altering the original active-turn object or any dialogue message. Textual conversation history intentionally remains complete and grows with conversation length; there is no claim of constant total memory or unlimited model context.

The installed release build logged interface registration at **97.3 ms**, prepared Host readiness at **222.0 ms**, and Agent connection/catalog readiness **1.147 s after the connection phase began**. These intervals start in the application controller, after AppKit process initialization; they are not end-to-end first-frame or reboot-cold measurements. Evidence: `.build/native-quality/installed-startup.log`.

## Verification and remaining acceptance boundaries

- `scripts/verify-mien.sh` passed: renderer build/security checks, 13 Pi runtime tests, 185 Swift tests passed (5 opt-in tests skipped), release build, strict formatting, native previews, shell and boundary checks. Evidence: `.build/native-quality/verify-final.log`.
- The final opt-in 24-turn probe repeated **2 WebViews / 93 descendant views**; the 60-turn resource/revisit regression passed. Evidence: `.build/native-quality/final-probes.log`.
- The final startup probe repeated **103.5 ms** of old MainActor integrity work versus a **6.3 ms** maximum MainActor heartbeat gap during **94.5 ms** background preparation; recovery and corrupt-journal rejection passed. Evidence: `.build/native-quality/final-probes.log`.
- The installed Pi helper passed the opt-in live four-turn probe in 36.1 seconds: evidence acquisition, switching from GPT-6.1-Terra to the account default, a self-contained greeting, and recalling both earlier typed answers after evidence release. Evidence: `.build/native-quality/live-agent.log`. The final Host-only timer/cancellation fix did not change the compiled Pi source or packaging inputs.
- `script/build_and_run.sh --verify` built, installed and launched `/Applications/Mien.app`; nested signatures and the single exact installed Host process were verified. Native UI inspection confirmed connected Codex and the preserved GPT-6.1-Sol preference. Both Mien capture permissions remained ungranted; no TCC settings were changed. Evidence: `.build/native-quality/install.log`.

The subsequent [design pass](design-pass-2026-11-17.md) replaces the earlier appearance and addresses the WebKit/native background mismatch. Complete VoiceOver/keyboard acceptance, real target capture under granted TCC, reboot-cold launch, RSS/energy percentiles and a long soak remain distinct acceptance work. An ad-hoc local install is not a notarized release or a claim that all release gates are met.

## Platform references

Apple recommends [reusing view-based table cells](https://developer.apple.com/documentation/appkit/nstableview/makeview(withidentifier:owner:)) through the table delegate. Its [launch-time guidance](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time) calls for reducing synchronous launch work, deferring nonessential work, and measuring separate launch conditions. These guide the native row and startup boundaries here.
