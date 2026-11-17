# Mien brand

## Core idea

Mien is the intelligence that understands both the person and the moment. The name refers to the manner, bearing, and expression through which character becomes visible. It gives the product room to grow beyond writing assistance without reducing it to a model, a cursor utility, or an automation framework.

**Promise:** Your intent, in context.

**Position:** A quiet native intelligence layer for macOS, invoked exactly where the user is already working.

**Product expression:** 在当前窗口，直接提问。 The interface makes the current window, the user's request, the answer, and the next available action clear. Brand character comes from the folded mark, considered proportions, and precise language.

## Naming

- The product, app, repository, and command are named **Mien** and `mien`.
- Use **Mien** alone in product copy. Add a descriptor only when the audience needs orientation: “native macOS intelligence layer.”
- Do not append “AI”, “Assistant”, “Copilot”, “Agent”, “Host”, or “OS” to the product name.
- Longview remains an independent capability and keeps its own name.

## Voice

Mien is calm, exact, and candid. Copy states what happened, what will leave the Mac, and what the user can do next. It never performs intelligence, anthropomorphizes uncertainty, or hides a limitation behind friendly filler.

- Prefer: “Using this conversation and your instruction.”
- Prefer: “Draft inserted. Undo for 30 seconds.”
- Avoid: “I magically understood everything on your screen.”
- Avoid decorative AI language, exclamation marks, and vague assurances.

## Visual identity

The mark is formed by two asymmetric planes meeting around an open center. It represents personal manner and situational context aligning into one deliberate action. The small ultramarine inflection is the moment intent becomes explicit.

The mark must remain recognizable as a simple silhouette at 16 px. It must not be redrawn as an eye, lens, aperture, cursor, chat bubble, robot, brain, sparkle, mascot, or literal letter.

| Role | Color |
|---|---|
| Graphite field | `#111214` |
| Warm plane | `#E8E2D8` |
| Steel plane | `#8A8C90` |
| Intent accent | `#1748B8` |

Use Apple system typography in the product: SF Pro through native text styles and SF Mono for machine-readable values. The interface inherits the current macOS material and accessibility settings; the brand does not impose a decorative typeface or theme over the platform.

## Product system

`MienAppearance` is the palette owner. Warm near-white and graphite provide stable reading surfaces in the system's light and dark appearances. Ultramarine is reserved for the primary available action; it does not imply success, permission, or connection. Text, separators, disabled controls, warnings, and failures use AppKit semantic colors. WebKit receives the same resolved surface and semantic colors from its owning window.

The conversation is 520 pt wide with an 18 pt silhouette and 20 pt content margins. The submitted request uses 13 pt medium secondary text, the answer and composer use 15 pt regular text, and controls use the system's compact sizes. The answer has the strongest reading presence. A fine outlined input separates editing from immutable content; nested glass, oversized capsule buttons, cards around answers, and decorative AI symbols are absent.

First use is a short sequence with one current action. Settings is a separate compact native window for account, model, permissions, and the shortcut. Copy and process disclosure are visible secondary controls; insertion and undo are explicit primary actions. No appearance, motion, or copy can claim more than live permission, verified connection, and typed task facts establish.

Use concrete verbs and ordinary product concepts in Chinese UI: “提问”, “复制”, “过程”, “打开系统设置”, “插入原输入框”. Provider names are appropriate when choosing an account or model. Runtime components and internal protocols stay in diagnostics. Permission instructions distinguish adding the app to Apple's list from enabling its switch.

The implementation and current verification scope are recorded in [the November 17 rebrand](mien/rebrand-2026-11-17.md); the interaction contract lives in [interaction-system.md](mien/interaction-system.md).

## Asset

The canonical raster source is `Resources/AppIcon/mien-1024.png`. `scripts/build-app-icon.sh` derives every shipping icon size from that source; generated derivatives are release artifacts, not editable masters.

`InteractionShell/MienMark.swift` owns the optically simplified monochrome derivative for the menu bar and conversation header. It preserves the two asymmetric planes and open center; AppKit renders the template image for the current appearance. The menu-bar attention dot indicates a retained task, never inferred success. Do not replace this derivative with a generic sparkle or targeting symbol.
