# Reading surface and native glass — 2026-11-17

Historical iteration: its lime palette, oversized typography, shared onboarding/settings layout, and glass input were superseded by [the subsequent rebrand](rebrand-2026-11-17.md). Retained engineering evidence is identified separately there.

The previous pass improved lifecycle and resource ownership, but its small type, repeated rules and default bezels still presented Mien as a utility dialog. This pass changes the actual AppKit interface around one composition: a light input capsule opens into a reading surface next to the target.

## Design decisions

- The question becomes a 22 pt semibold heading; the answer uses 16 pt system text with 1.65 line height. Whitespace replaces per-turn separators. The 600 pt panel has 24 pt margins and a 28 pt silhouette, with a bounded scrolling transcript and a pinned composer.
- Reading uses a warm opaque paper surface, in both system appearances. Native glass belongs to the 18 pt input/control layer. Lime identifies submission and the next explicit action, with dark ink; it does not signal task success.
- Copy and process details share a native ellipsis menu. Insert, undo, authentication and retry remain explicit controls. Native text selection, marked text, menu commands, focus and accessibility roles remain AppKit-owned.
- Settings use the same palette, enlarged type and numbered connection/sensing groups. The model list remains account-discovered; no model names or readiness facts are invented for styling.

The larger typography reduces visible history at a fixed height. Native row reuse keeps the number of live renderers bounded; full conversation data remains intact. Glass is `NSGlassEffectView` on macOS 26+, with the same layout using AppKit material on supported macOS 14–15. This is a deliberate platform implementation, not silent failure recovery.

## Failure paths corrected

- An asynchronously loaded WebKit page could show a mismatched light/dark rectangle. The Host now supplies the resolved paper background and its effective window `color-scheme` before showing the renderer. Static Markdown, CJK handling and the offline security boundary are unchanged.
- A historical row brought into view during final preview resizing could be captured before its new renderer finished. Preview capture now waits for measured, rendered visible content with an explicit four-second timeout.
- Hiding the glass effect directly left its composited input visible over a submitted question in native snapshots. A normal AppKit container now owns visibility for the complete glass subtree; the draft and authentication states show only their immutable question.
- The previous window height and the content's requested height constrained the same stack during resizing. The viewport now owns its explicit height, and the controller starts at a real usable size. Resource tests set their intended viewport after assigning the content controller, matching AppKit's window-sizing lifecycle.
- The full suite exposed a run where 60 offscreen renderers remained attached after rapid insertion. Teardown now follows the visible row range as well as AppKit's row-removal callback. Available cached cells release their content outside that range, and reconstruct it from the transcript when scrolling back. Expensive resources no longer depend on when AppKit removes a reusable row.
- The login fixture exposed an incomplete motion-settling path: its action/footer could still be transparent when captured. Terminal content now has one fade owner; restored rows and Reduce Motion commit visibility directly, and preview settling includes status and action controls.

## Verification

Evidence is local under `.build/design-pass/`. `after/` and `dark/` contain actual AppKit-rendered fixtures, not real Agent replies. The permission-guide fixture still uses its original system appearance; `--all-dark` covers the conversation and readiness surfaces.

- `scripts/verify-mien.sh` passed: 186 Swift tests passed, 5 opt-in tests skipped; 13 Pi tests and 4 renderer tests passed. Release build, strict formatting, bundle resources, native preview generation and boundary checks passed, with no conflicting-constraint warnings. Evidence: `verify.log`.
- The opt-in 24-turn rendered workload retained **2 WebViews and 88 descendant NSViews**. The 60-turn release/revisit/reset regression also passed. These are local structural counts, not an RSS or energy benchmark. Evidence: `resources.log`.
- `script/build_and_run.sh --verify` builds, installs and launches `/Applications/Mien.app`, verifying one exact Host process and nested signatures. The final run is recorded in `install.log`; the first installed candidate inspected below used PID 70986. The install script resets local TCC records after an ad-hoc signing identity change; neither capture capability was granted.
- Native inspection confirmed the new settings surface, connected Codex, the preserved GPT-6.1-Sol preference and a server-discovered model menu containing the current GPT-6/6.1 families. An automation timeout prevented readback after pressing Escape. A subsequent one-second process sample showed the main thread in its normal AppKit event loop, with no busy loop observed; that does not substitute for the missing keyboard UI assertion. Evidence: `installed-sample.txt`.

Full VoiceOver navigation, all accessibility display combinations, older supported macOS versions, and target acquisition under granted TCC remain separate acceptance boundaries. The design is implemented and locally installed; visual acceptance by the user is not assumed.

## Platform guidance

Apple's [materials guidance](https://developer.apple.com/design/human-interface-guidelines/materials) distinguishes the control/navigation layer from reading content. [`NSGlassEffectView`](https://developer.apple.com/documentation/appkit/nsglasseffectview) owns native glass and its `contentView`; the app does not simulate refraction or implement a second input system.

Modern Web Guidance's `dark-mode` guide says: “Apply the `color-scheme` property to the `html` element or the `:root` pseudo-class.” The embedded document follows the owning native window through `document.documentElement.style.colorScheme`, alongside the exact resolved native background.
