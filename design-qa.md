# Design QA — native task overlay

Current direction and verification are in [the 2026-11-17 rebrand](docs/mien/rebrand-2026-11-17.md). It supersedes the visual decisions in [the earlier design pass](docs/mien/design-pass-2026-11-17.md), while retaining the bounded transcript and lifecycle work from [the interaction quality pass](docs/mien/quality-pass-2026-11-17.md) and [native lifecycle work](docs/mien/native-quality-2026-11-17.md). The findings below record the earlier July native-overlay iteration; they are not current whole-product acceptance or a claim that all P1/P2 issues are closed.

- Problem evidence: `/var/folders/ry/mpc3hlzn3wxcy6g5hypd3mwc0000gn/T/codex-clipboard-5032c92e-c634-4ae1-b9e0-47ca943385f5.png`
- IME problem evidence: `/var/folders/ry/mpc3hlzn3wxcy6g5hypd3mwc0000gn/T/codex-clipboard-27bc7aab-a231-401b-88de-6e3861a223d5.png`
- Readiness problem evidence: `/var/folders/ry/mpc3hlzn3wxcy6g5hypd3mwc0000gn/T/codex-clipboard-f0ac1866-2fb1-4268-a786-61b6c6108c44.png`
- Final implementation: `/Users/kohozheng/.codex/visualizations/2026/07/29/mien-native-rebuild-composing.png`
- Same-state, same-viewport comparison: `/Users/kohozheng/.codex/visualizations/2026/07/29/mien-native-rebuild-comparison.png`
- Native readiness implementation: `/Users/kohozheng/.codex/visualizations/2026/07/29/mien-native-settings.png`
- Scope: the transient task overlay in its empty composer, IME composition, submitted turn, activity, result, follow-up, action-required, retry, and login states; plus the shared onboarding/settings window.

## Native sources of truth

- Surface: `NSVisualEffectView.Material.popover`, behind-window blending, system appearance, and the native window shadow.
- Shape: one stretchable `NSVisualEffectView.maskImage` supplies the rounded alpha silhouette to both the material and AppKit's native window-shadow compositor.
- Typography: AppKit preferred macOS text styles (`body`, `callout`, `subheadline`, `caption1`) and system script fallback. No embedded PingFang family and no Light or UltraLight body text.
- Color: `labelColor`, `secondaryLabelColor`, `tertiaryLabelColor`, `placeholderTextColor`, `textColor`, `controlTextColor`, and semantic warning/error colors.
- Controls: standard circular submit button, accessory-bar close button, disclosure button, push buttons, `NSProgressIndicator`, `NSBox` separators, `NSScrollView`, `NSTextView`, and SF Symbols.
- Readiness: standard titled `NSWindow`, system appearance, plain AppKit rows, `NSBox` separators, `NSPopUpButton`, and standard default/secondary push buttons.

## Findings

- P0: none.
- P1: none. The old 700 × 96 pt resting surface was visually oversized and devoted most of its height to custom chrome. The native resting surface is 560 × 74 pt, removes the persistent application/scope/evidence line, preserves the Escape path, and keeps the text entry aligned to the 16 pt content margin.
- P2: none. The custom warm wash, three-stop gradient, white border, fixed black alpha palette, explicit PingFang Light typography, hand-rendered dividers, result mask, dotted completion glyph, and borderless image buttons were removed.
- Rendering regression: the live borderless panel previously clipped only its backing layer, so AppKit retained a rectangular shadow silhouette and exposed four square corner patches. The visual-effect mask now owns the same rounded silhouette as the material, and the native shadow is invalidated after presentation and resizing.
- Interaction: Return submits, Shift/Option-Return inserts a line break, Escape and the close control dismiss, the submit control inherits native enabled/disabled/pressed states, and completed process disclosure uses the standard AppKit disclosure control.
- Input methods: marked text now suppresses the placeholder immediately and cannot submit until AppKit commits the composition. Mien does not draw, reposition, or imitate the system candidate panel.
- Readiness: the forced light appearance, hidden titlebar, large custom hero, rounded white cards, shortcut pill, custom accent outlines, green status typography, and manually tinted capsule CTA were removed. The shared onboarding/settings surface now follows standard macOS window and control behavior.
- Accessibility: controls keep explicit labels and help, the removed visible context disclosure remains attached to the conversation surface as accessibility help, text uses macOS default and minimum sizes, the surface follows system appearance/transparency/contrast behavior, and Reduce Motion resolves the same states without animation.
- Product invariant: activity remains standardized typed Host/ACP metadata only. Raw reasoning, tool payloads, and unvalidated Agent prose are not projected.

Historical iteration result: passed within the recorded scope.
