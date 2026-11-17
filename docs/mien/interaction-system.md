# Interaction system

Current visual direction: the logo’s warm white, graphite and ultramarine expressed through a compact native reading surface, described in [the November 17 rebrand](rebrand-2026-11-17.md). The earlier [interaction study](visual-target.png) records the original concept, not the current visual specification.

Implementation status: the native slice includes Halo, a continuous conversation transcript, immutable sent turns, observable Agent activity, follow-up, accessibility context disclosure, device login, verified draft insertion, bounded undo, and detachment to one menu-bar task center. Inline ghost text inside arbitrary third-party fields is deliberately not claimed; explicit insertion is the current trust-preserving acceptance model.

## User grammar

The complete visible system has four objects:

1. **Halo** — “I mean this.”
2. **Context Lens** — “It can see this much.”
3. **Conversation Transcript** — “It is working here, and I can continue.”
4. **Receipt + Undo** — “It changed this, and I remain in control.”

The actual cursor is never replaced, moved, or decorated permanently.

## Readiness

First launch and Settings are separate projections of one live readiness policy. Setup is a 480 × 340 pt native window with the canonical logo, a brief orientation, and one current action: connect the ChatGPT account, authorize the first reading capability, or begin. Browser authorization displays the exact selectable code and waits for verified connection. A removed saved model exposes a model choice; failed discovery exposes an explicit reload. With an authorized reading route, optional screen capture never delays first use.

Settings is a compact 520 × 400 pt native window titled “Mien 设置”, reached through an ordinary menu-bar click or Command–Comma. It contains account status, the live model picker, two independently managed permissions, and shortcut guidance. The account/model/permission state is refreshed from the same authoritative snapshot as setup and invocation. `NSPopUpButton` owns model selection and target-action routing; unchanged catalog refreshes preserve the menu, while verified reconnection re-enables an unchanged catalog. Settings has no onboarding hero or numbered setup sequence.

The menu bar uses the logo's monochrome silhouette and a standard `NSMenu`. Its first command accurately says “完成设置…”, “对当前窗口提问”, “返回当前任务”, or “继续对话”. A retained conversation always restores its original target. Native App and Edit menus provide Settings, Quit, copy/paste, undo/redo and selection through the responder chain. An invocation without a valid target presents an accessible next-step popover at the menu-bar entry and logs the typed failure; it never guesses a substitute target or fails with only a beep.

Agent connection is first-class product readiness. The Host verifies the bundled Pi runtime, private credential home, bounded transport handshake, and negotiated Agent identity. Missing credentials use Pi's OpenAI Codex subscription device-auth flow inside Mien; its exact browser code is visible until confirmation. A failed connection has an explicit reconnect path, and Settings remains available from the menu-bar item.

An expired subscription that cannot refresh exposes **连接 ChatGPT** on the failed turn and reconnects through the same App-owned login flow. Mien displays the device code, opens the official authorization page, and waits for the completed credential plus a verified Agent connection. It then resumes the immutable original turn through normal target renewal and a fresh Host task; the old target lease is never reused after the browser detour. Duplicate login actions cannot spawn parallel login processes, and dismissing the pending turn cancels its recovery.

The Host never maintains or guesses a model list. On connection and whenever Settings opens, it opens one prompt-free discovery session, reads the Agent's typed `model` configuration, and closes that session. The Agent fetches the account’s current server catalog; names, picker visibility, priority, and the new-conversation default come from that response. A read failure disables the selector, preserves the saved preference, blocks readiness, and offers “重新读取模型”. An explicit selection persists as one exact model ID. Before every fresh task binding, the Host compares that preference with the idle conversation session, validates it against the session's typed catalog, and applies any change with `session/set_config_option` before the verbatim user turn is sent. “Default” restores the original Agent default captured when that conversation session opened. A task already in progress can never change model, and a disappeared model blocks the next task instead of silently falling back.

The triggering permission control is the visual origin of a short transition into a bounded guide attached to the active System Settings content pane. The guide contains the signed Mien app as a Finder-compatible drag source, because macOS can open a permission pane before Mien has a row to toggle. During a drag the guide becomes mouse-transparent and moves behind System Settings so Apple's list owns the drop. Clicking the app card reveals the same bundle in Finder; keyboard and assistive-technology users can use the pane's standard add button instead. The guide follows the settings window, offers an explicit route back when it loses focus, and performs no permission decision itself.

Permissions refresh when Mien becomes active and once per second while incomplete permissions are visible. Unchanged snapshots do not redraw the controls; permission polling stops once permission readiness is complete, independently of model discovery. The separate System Settings guide checks geometry at 10 Hz and only moves when the frame changes; it does not repeatedly raise an unchanged window. Readiness is live: Mien is usable when the Agent handshake and selected model catalog are verified and at least one sensing route is authorized; both routes yield full readiness. The persisted introduction flag controls only first-run presentation and never overrides Agent or TCC truth. Authorization does not widen task scope: only a typed Agent request may select a granted capability.

## Interaction states

### Dormant

No visible product UI, no active screen stream, no AX traversal, and no mouse polling. Idle CPU and power use are release gates.

### Prime

`Control–Option–Space` freezes the pointer, frontmost app, exact WindowServer window, display, AX hit element, focused element, selection, and user input epoch. The first halo frame should appear within 50 ms p95; the composer should accept input within 85 ms p95.

### Compose

The composer is a native text input in a fine outlined surface pinned below the scrollable transcript near the target. It stays reachable while the user browses history. AppKit reuses transcript rows; complete message data and disclosure state survive offscreen renderer release. Sending removes the input and presents its verbatim text as an immutable, selectable heading. A completed answer opens a fresh composer; whitespace separates turns without repeated rules or chat bubbles. The compact header names only the exact target application and offers `esc` plus the close control. It never claims an evidence scope before acquisition and contains no model, protocol, token, or log details.

Default keys:

- `Return`: run.
- `Shift-Return` or `Option-Return`: insert a newline.
- `Esc`: dismiss and preserve the source.
- `Command-Return`: perform the explicit result action, such as inserting or undoing a draft.
- `Command-Comma`: open Mien Settings.
- `Command-W`: close the window; in the conversation panel this follows the same cancellation and cleanup path as Escape.

The quiet leading span of the top chrome is a native AppKit drag region. A mouse-down there calls `NSWindow.performDrag(with:)`; close, Escape, transcript selection, process disclosure, and composer controls retain their own hit testing. The whole surface is never made implicitly draggable.

CJK marked text hides the empty-state placeholder as soon as AppKit begins composition and must never submit before the input method commits it. The candidate panel, marked-text attributes, and commit lifecycle remain owned by the native AppKit text system.

Accessibility evidence reports the narrowest root actually proven by the adapter. Geometry alone never upgrades a pointed element to a semantic region. A conversation scope is claimed only after locating a matching container ancestor; otherwise the narrower pointed-element artifact remains valid and the manifest records the degradation. Broker rejection evidence names the failed contract field without logging captured content.

### Sense

Users see what is being acquired through typed lifecycle activity, not an acquisition selector or a concatenated chrome label. The Agent may request interface structure, current pixels, visual history, or a combination; the Host keeps every acquisition interruptible and exposes the aggregate context/destination disclosure as accessibility help on the conversation surface.

### Work

Submitting a turn immediately shows the single local state “正在准备请求”; it describes submission only and disappears on the first Agent activity or terminal result. Once the Agent emits standardized activity, the presentation module maps only kind, status, and known tool identity to concise product language such as “准备所需内容” and “整理回答”. Raw protocol titles, plan prose, reasoning, inputs, outputs, and command text are never displayed as progress. At most four recent rows are visible and 24 are retained. Completion collapses recorded activity into the native disclosure control; the typed Host outcome remains the only task-success authority.

Fast tasks remain in place. Deep tasks detach to the source window corner and then to a single menu-bar task center if the user leaves the window. Multiple tasks never create multiple roaming desktop bubbles.

### Result

- Agent prose appears only after typed outcome validation. A narrow offline `WKWebView` renders that immutable result with the pinned Streamdown static Markdown renderer, including CJK-correct emphasis, lists, tables, quotes, safe links, and code typography; there is no token-streaming claim because `submit_outcome` is already terminal. Raw HTML, remote images, scripts, forms, frames, workers, and renderer network access are disabled. The renderer is allocated only when a nonempty validated result exists, so submission, login and ordinary errors create no WebView. The result remains selectable and fades in without an assistant bubble, avatar, or extra card. The copy control copies the entire immutable Markdown only when the user clicks it. Copy and process disclosure share one compact footer; a collapsed process does not leave an empty row above the answer. Window resizing coalesces multiple content changes within one main-loop turn.
- A completed answer keeps its submitted turn and result immutable, then opens one fresh glass follow-up input below the transcript.
- A retryable failure remains visible with a real retry control. Retrying preserves the immutable submitted text, renews the exact target, and creates a fresh ledger task; it does not silently edit or duplicate the turn.
- Each follow-up retains Agent conversational continuity but renews the exact original window identity and creates a separate ledger-backed task with fresh evidence, validation, and cleanup.
- Answers begin with one to three short paragraphs.
- Drafts remain in Mien until the user explicitly chooses “Insert into original field”.
- Insertions are read back before success is shown; failed verification rolls back automatically.
- For 30 seconds, “Undo insertion” restores the prior value only if the user has not changed the field again.
- Reversible writes show the smallest meaningful diff.
- External consequences are confirmed at the final commit point.
- Every completed mutation exposes a concise receipt and undo.

The product never sends a message automatically by default.

## Visual language

- AppKit owns the windows, input system, submitted turns, process disclosure, lifecycle state, actions, focus, dragging, and controls. WebKit only typesets a validated immutable result.
- `MienAppearance` owns warm near-white and graphite surfaces plus the logo's ultramarine primary action. `MienMark` owns the small monochrome mark. Labels, placeholders, disabled states, warnings, and failures use semantic system colors; color alone conveys no state.
- Conversation width is 520 pt with an 18 pt corner and 20 pt content margins. Submitted requests use 13 pt medium secondary text; answers and input use 15 pt regular. Height is bounded by the smaller of 580 pt and 62% of the display, after which the native transcript scrolls. Input grows from 32 to 96 pt plus 12 pt of container padding, then scrolls internally. Viewport height owns layout; no redundant bottom constraint fights window resizing.
- A matte reading surface, native window shadow, and one visual-effect mask define the panel silhouette. A fine outline separates the editing surface; no nested glass surrounds text. WebKit receives the exact native background and appearance before becoming visible.
- `MienAccentButton` retains native button behavior, focus, target-action and accessibility, drawing an 8 pt rounded ultramarine fill with distinct pressed and disabled states. Increase Contrast adds an outline. Ordinary secondary controls use native AppKit styling.
- Copy and “过程” are visible secondary buttons beneath an answer. The process button discloses only typed activity and changes its chevron with expansion. Copy acknowledges completion visually and through an accessibility announcement. Explicit insertion and undo remain visible primary actions. Activity uses `NSProgressIndicator`.
- The offline typesetter uses the system font, host-projected `rem` size, unitless 1.6 line height, deliberate paragraph wrapping and balanced headings. No external font or network content is needed.
- Spacing, alignment and type hierarchy separate content. No assistant avatar, chat bubble, persistent orb, or decorative AI symbol competes with the source window. Increase Contrast, Reduce Transparency, Reduce Motion, Full Keyboard Access and VoiceOver are required validation states.

## Motion

- Activation: 120 ms opacity transition; optional 0.98-to-1 scale only when Reduce Motion is off.
- Scope change: 160 ms anchored geometry interpolation.
- Detachment: short position/opacity transition, no spring.
- Turn submission immediately replaces the editable input with immutable text. Results fade in over 200 ms and the follow-up input over 240 ms; neither transition controls readiness.
- Completion commits the terminal state, result/action and follow-up availability synchronously. Decorative fades never delay editing or install a later focus change. The previous 120 + 160 + 140 ms readiness delay and trailing 300 ms completion task are removed; Reduce Motion changes only visual interpolation.
- Every animation is interruptible and never blocks keyboard input.

## Accessibility

Pointer is a preferred reference method, not a required motor action.

- Keyboard focus and selection can become the target.
- Full Keyboard Access, VoiceOver, Switch Control, Voice Control, Mouse Keys, Head Pointer, and Dwell remain viable.
- Halo exposes an AX description such as “current email thread, 12 messages”.
- No hover-only controls or timing-dependent gestures.
- Sticky Keys and Slow Keys do not break the shortcut.
- Process rows announce typed status changes; terminal result, action, warning, and failure states post standard AX layout/status notifications without moving VoiceOver to a new composer.
- The rendered result exposes WebKit's standard document semantics for headings, emphasis, links, lists, tables, quotes, and code while the transcript model remains the lifecycle owner and AppKit cells are disposable projections.
- All context, progress, approval, retry, undo, and receipts have standard AX roles and labels.

## Error language

Errors state what changed and what remains safe:

- “This content changed. Read it again to continue.”
- “Only the visible area is available. Select a region or read more.”
- “The draft is preserved, but this app does not support direct insertion.”
- “The action was not verified, so later steps were stopped.”
- “The task was cancelled. The original position was restored.”

“Something went wrong” is never a terminal product state.
