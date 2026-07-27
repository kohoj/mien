# Interaction system

Visual target: [unified Mien interaction](visual-target.png).

Implementation status: the native slice includes Halo, composer, clickable and keyboard submission, task status, explicit context/destination disclosure, device login, a result, explicit verified draft insertion, bounded undo, and detachment to one menu-bar task center. Inline ghost text inside arbitrary third-party fields is deliberately not claimed; explicit insertion is the current trust-preserving acceptance model.

## User grammar

The complete visible system has four objects:

1. **Halo** — “I mean this.”
2. **Context Lens** — “It can see this much.”
3. **Task Capsule** — “It is working here.”
4. **Receipt + Undo** — “It changed this, and I remain in control.”

The actual cursor is never replaced, moved, or decorated permanently.

## Interaction states

### Dormant

No visible product UI, no active screen stream, no AX traversal, and no mouse polling. Idle CPU and power use are release gates.

### Prime

`Control–Option–Space` freezes the pointer, frontmost app, exact WindowServer window, display, AX hit element, focused element, selection, and user input epoch. The first halo frame should appear within 50 ms p95; the composer should accept input within 85 ms p95.

### Compose

The composer is one native single-line field near the target. It shows one human context label, never model names, protocol names, tools, tokens, or logs.

Default keys:

- `Return`: run.
- `Esc`: dismiss and preserve the source.
- `Command-.`: cancel an active task.
- `Command-Up/Down`: expand or contract semantic scope.
- `Command-Return`: perform the explicit result action, such as inserting or undoing a draft.

CJK marked text must never submit on `Return`.

### Sense

Users see semantic scope, not acquisition technology. Scope names are app-aware: “this message”, “current thread”, “this chart”, or “more history”. Halo expansion follows the source object and remains interruptible.

### Work

No spinner appears for the first 400 ms. After that, the capsule shows verified verbs such as “Reading 18 messages” or “Draft ready”. It never shows hidden reasoning or a generic infinite “Thinking”.

Fast tasks remain in place. Deep tasks detach to the source window corner and then to a single menu-bar task center if the user leaves the window. Multiple tasks never create multiple roaming desktop bubbles.

### Result

- Answers begin with one to three short paragraphs.
- Drafts remain in Mien until the user explicitly chooses “Insert into original field”.
- Insertions are read back before success is shown; failed verification rolls back automatically.
- For 30 seconds, “Undo insertion” restores the prior value only if the user has not changed the field again.
- Reversible writes show the smallest meaningful diff.
- External consequences are confirmed at the final commit point.
- Every completed mutation exposes a concise receipt and undo.

The product never sends a message automatically by default.

## Visual language

- Native AppKit controls and materials; no web-view simulation.
- One restrained ink-blue accent; state never relies on color alone.
- 1–1.5 pt semantic outline with a very light glow only at activation.
- Composer width 336–420 pt, 13 pt continuous corner, 14–15 pt input text, 11.5–13 pt context text.
- Spacing, alignment, and typography do most separation; borders and shadow are last resorts.
- No assistant avatar, sparkle logo, personality typing bubble, neon, liquid-glass showcase, or persistent floating orb.
- Dark, light, Increase Contrast, Reduce Transparency, and Reduce Motion are first-class states.

## Motion

- Activation: 120 ms opacity transition; optional 0.98-to-1 scale only when Reduce Motion is off.
- Scope change: 160 ms anchored geometry interpolation.
- Detachment: short position/opacity transition, no spring.
- Completion: one quiet luminance confirmation.
- Every animation is interruptible and never blocks keyboard input.

## Accessibility

Pointer is a preferred reference method, not a required motor action.

- Keyboard focus and selection can become the target.
- Full Keyboard Access, VoiceOver, Switch Control, Voice Control, Mouse Keys, Head Pointer, and Dwell remain viable.
- Halo exposes an AX description such as “current email thread, 12 messages”.
- No hover-only controls or timing-dependent gestures.
- Sticky Keys and Slow Keys do not break the shortcut.
- All context chips, progress, approval, undo, and receipts have standard AX roles and labels.

## Error language

Errors state what changed and what remains safe:

- “This content changed. Read it again to continue.”
- “Only the visible area is available. Select a region or read more.”
- “The draft is preserved, but this app does not support direct insertion.”
- “The action was not verified, so later steps were stopped.”
- “The task was cancelled. The original position was restored.”

“Something went wrong” is never a terminal product state.
