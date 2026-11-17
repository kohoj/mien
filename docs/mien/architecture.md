# Mien — architecture

Status: working developer preview. The ownership boundaries below are implemented; the remaining production gates are tracked separately in `release-status.md`.

## Product invariant

The product is a local macOS trust kernel for spatial intent, not a mouse replacement and not a generic Codex chat shell.

```text
pointer / selection / keyboard focus
    -> immutable target lease
    -> verbatim turn in one conversation-bound Agent session
    -> fresh ledger task and renewed exact target authority
    -> typed Agent context decision (none or one exact request)
    -> Host-authorized evidence manifest when requested
    -> typed Agent outcome proposal
    -> host policy and execution
    -> postcondition verification
    -> recovery receipt and undo
```

The Agent is the sole owner of semantic interpretation. The Host does not parse wording, classify intent, select a default scope, or infer whether the user wants an answer or draft. The Agent never owns target identity, context authorization, TCC handles, execution authority, or the fact that an operation succeeded.

## Three buses

### Reference bus

`Global shortcut -> pointer/window/AX hit-test -> InvocationSnapshot -> TargetLease`

It freezes the target before the product overlay becomes key. `PID + WindowServer windowID + frame + AX fingerprint + userInputEpoch` are the minimum stable identity. Window title is mutable metadata and never a lease key.

### Context bus

`verbatim input -> Pi request_context decision -> none OR selection / AX / current frame / visual history -> optional ContextManifest -> same Agent loop`

The Agent explicitly selects either no external evidence or the minimum evidence class, including multimodal combinations. The Host mechanically maps a typed request to available adapters and may only validate authority, policy, budget, target lineage, and protocol shape. It never infers the no-context route or substitutes a semantically guessed request. Every acquired artifact carries provenance, sensitivity, trust level, TTL, and a target lease.

### Execution bus

`Pi Agent proposal -> capability grant -> typed action -> verifier -> recovery -> receipt`

No model response is directly executable. Shell, AppleScript, Python, arbitrary AX actions, and unrestricted coordinate clicks are not product capability surfaces.

## Process boundary

```text
Signed macOS Host
├── InteractionShell
├── InvocationKernel
├── ContextKernel + ProviderAdapters
├── PolicyKernel
├── TaskRuntime + local ledger
├── ActionKernel + Verifier + RecoveryManager
├── private ArtifactStore / provenance-aware MemoryKernel
├── private CapabilityBroker
└── pinned Pi Agent child (Codex subscription, no desktop capability handles)
    ├── request_context
    └── submit_outcome
```

The Host is the only durable TCC identity. ACP and MCP children do not receive Accessibility or Screen Recording handles. A signed Host may initially keep sensing and deterministic action in one process to avoid fragmented TCC prompts; agent isolation is mandatory from day one.

## Modules and ownership

| Module | Owns | Must not own |
|---|---|---|
| `InteractionShell` | hotkey, semantic halo, composer, task capsule, accessibility UI | desktop capture, Agent runtime, policy |
| `InvocationKernel` | atomic target freeze, coordinates, WindowServer/AX identity | overlay UI, mutation |
| `MienContracts` | wire-stable immutable contracts | providers, side effects |
| `ContextKernel` | typed evidence routing, budgets, coherence, omissions | direct UI, agent sessions, semantic interpretation |
| `ProviderAdapters` | narrow provider translation, including Longview schema v2 | product policy, generic automation |
| `PolicyKernel` | deterministic subject/operation/sensitivity/destination decisions | prompt interpretation |
| `TaskRuntime` | event-sourced lifecycle and terminal truth | UI phrasing, hidden mutable state |
| `ACPGateway` | ACP v1 framing, typed session/model configuration, supervised process lifecycle | desktop capabilities |
| `HostRuntime` | conversation session composition, single active task binding, live model validation, typed protocol validation | user-input interpretation, platform mechanisms |
| `ActionKernel` | typed mutations, compare-and-swap, inverse operations | general-purpose click/type/shell |
| `DesktopActionAdapters` | exact AX field read/write/read-back/rollback/undo transaction | send, click, key events, clipboard, generic AX action |
| `MemoryKernel` | namespaced claims, provenance, candidates, expiry | raw always-on screen recording |

## Native application lifecycle

The AppKit delegate only translates launch and termination callbacks. `MienApplicationController` owns UI wiring, startup, connection/login, model discovery and shutdown. `MienRuntimeBootstrap` is an actor owning startup filesystem I/O, recovery, credential preparation and bundled executable verification. The interface is installed with `.checking` readiness before preparation; no task can run until recovery and live readiness checks succeed. Startup failures log a content-free error and present a native alert instead of silently exiting.

`MienConversationController` owns one visible conversation, its exact task bindings, typed context/outcome flow and pending draft/undo transactions. `ConversationWorkQueue` serializes turns and teardown: a replacement cancels active/queued execution, awaits its settlement and never cancels required cleanup. Dismissal closes the conversation and workspace as tracked work; the next invocation and application termination both await it. Startup and connection work are also cancelled and awaited on termination.

Startup logs distinguish `interface_ready`, `runtime_prepared` (recovery and verification durations), and `host_ready`. None claims that the network-backed Agent/model catalog or TCC capabilities are ready; those remain separately derived facts.

## Core contracts

### `InvocationSnapshot` and `TargetLease`

Captured at keydown before any product window can affect focus. A lease expires, is revalidated before mutation, and fails closed when PID, windowID, AX fingerprint, frame tolerance, Space, or user input epoch changes.

### `ContextArtifact` and `ContextManifest`

Raw content is stored as a private immutable artifact. The manifest contains ordered references, included and omitted scope, redactions, destination decision, coherence status, and a digest. Ledger events keep digests and provenance instead of duplicating private payloads.

### `AgentContextDecision`, `AgentContextRequest`, and `AgentOutcome`

One Pi Agent loop receives the verbatim user turn and must first call `request_context` with a schema-v1 `AgentContextDecision`. `none` carries `request: null` and proves the Agent—not Host heuristics—decided that the verbatim turn and conversation are sufficient. `request` carries one exact catalog entry: selected text, Accessibility, current frame, visual history, or a valid combination. The Host rejects malformed, repeated, unavailable, conflicting, or authority-expanding decisions without keyword heuristics or prose recovery. The Agent then must finish through `submit_outcome` with a typed `answer` or `draftProposal`; Host code never classifies the result text and never treats ordinary agent prose as an outcome.

### Result rendering boundary

`InteractionShell` passes only a validated terminal `AgentOutcome.content` string to `ResultWebRendererView`. On the first nonempty result, the view lazily creates WebKit and loads three pinned local resources inside a nonpersistent `WKWebView` and calls one page function with structured JavaScript arguments; content is never interpolated into source. Streamdown runs in static mode with its CJK plugin, raw HTML disabled, a strict element allowlist, and a URL transform that rejects images and every link scheme except `https` and `mailto`. Content Security Policy denies network, image, frame, object, media, form, font, and worker access. WebKit can return only a finite bounded layout height; it never returns result text, tool data, or authority to the Host. User-activated safe links are cancelled in the page and handed to `NSWorkspace`; every other navigation is denied.

`InteractionShell/MienReadinessState.swift` owns the derived readiness and next-action policy. `MienReadinessController` in `PermissionOnboardingController.swift` owns live refresh, model preference, and window lifetime. `MienSetupViewController` projects the single next action; `MienSettingsViewController` projects account, model, permissions, and shortcut settings. Their `ReadinessActions` interface carries commands without duplicating readiness policy. One authorized reading route permits first use; optional capture never becomes an extra prerequisite. `SystemSettingsGuide.swift` independently owns the native permission-guide window, drag source, and geometry tracking.

`TaskCenterController` owns the standard menu-bar menu and application commands. It receives live readiness and conversation existence; clearing a detached-task badge never makes a retained conversation appear to target a new window. `InvocationFeedback` maps typed target-resolution errors to next-step copy, with an accessible native popover and content-free logging. No identity error silently degrades to a guessed target. `AgentActivityPresentation` owns the vocabulary for standardized activity; the application maps typed enums and tool identity without forwarding remote prose. A conversation turn commits terminal state synchronously; animation never controls when it becomes editable.

`ConversationTurn` owns immutable submitted text and lightweight outcome/activity state. `ConversationTranscriptView` projects it through a view-based `NSTableView`, using AppKit's reuse queue. The visible row range and row-removal callback release offscreen cell content, including rows AppKit temporarily keeps attached. Returning to a row reconstructs the exact Markdown and disclosure state without replaying completion announcements. Measured result heights prevent temporary shrinkage while WebKit reloads. Height callbacks are checked against the transcript generation and row identity; the scroll anchor is preserved during relayout. The native composer is pinned below the scrolling history. Historical action buttons cannot act on the current task binding.

The WebKit boundary owns document typesetting only. AppKit remains the sole owner of composition, marked text, immutable submitted turns, task activity, outcome validation, retry/action controls, scrolling, focus, accessibility announcements, window dragging, and dismissal. Missing or crashed renderer resources produce one explicit blocking display failure and a structured content-free log event; packaging makes those resources, their CSP, their transitive licenses, and their SBOM entries mandatory.

`MienAppearance` owns the native reading-surface palette and icon-derived ultramarine action accent. `MienMark` owns the small monochrome derivative of the canonical app icon. `ResultWebRendererView` projects its effective window appearance, resolved background, font size and semantic text colors into the offline document, including the root `color-scheme`; it remains hidden until that projection succeeds. A simple outlined AppKit input container owns visibility and layout. Copy and process disclosure are visible native buttons; explicit mutation actions retain primary emphasis. Styling does not own task state or authority.

### `TaskCapsule`

The unit of one conversation turn: verbatim intent, renewed target lease, manifest, desired outcome, allowed action classes, approval policy, deadline, and ACP session binding. Conversation history never substitutes for fresh Host authority.

### `CapabilityGrant`

A short-lived, exact-tool, exact-action, maximum-scope, bounded-use authorization tied to one task and one target lease. High-risk grants require approval provenance.

### `MutationReceipt` and `RecoveryReceipt`

A mutation is successful only when its postcondition is independently verified and all affected environment facets are clean. “Tool call returned success” is never a product success state.

## Task lifecycle

```text
created
  -> targetLocked
  -> contextPlanning
  -> contextReady | degraded
  -> agentRunning
  -> awaitingPermission | executing | verifying
  -> reversibleWindow
  -> restoring
  -> succeeded | partial | failed | cancelled
  -> cleanupVerified
```

Events have a monotonic sequence, actor, input digest, artifact references, timestamp, and reason. UI is a projection of the ledger rather than a parser over agent prose.

## Context acquisition rules

1. Freeze target identity before the Agent session can request evidence.
2. Give the Agent the user input verbatim, non-content target metadata, and a bounded capability catalog.
3. Accept exactly one typed context decision. `none` advances without acquisition; `request` must match one advertised catalog entry. Never infer either route from wording or install a fallback parser.
4. Capture every evidence class the Agent requested, including valid AX-plus-visual bundles, under one coherence group.
5. Never start a continuous screen stream while idle.
6. Longview supplies one current frame or bounded visual history. Visual history walks backward from the current viewport, and its receipt must prove viewport, focus, pointer, and environment restoration. If a lazy-load or live update later breaks continuity, Longview may return only the preceding verified prefix with `continuity-lost`; the Host marks it incomplete and exposes the omitted remainder to the Agent.
7. OCR/VLM output is untrusted derived data and cannot widen permission.
8. Memory retrieval is another explicit Agent-requested artifact and remains visible to the user.

## Execution rules

Route order:

```text
native connector
  -> deterministic AX value/action
  -> verified targeted event delivery
  -> constrained visual grounding fallback
  -> structured unsupported
```

Every action declares preconditions, exact target, bounded parameters, expected postcondition, risk class, inverse operation, and restoration strategy. Tasks mutating the same target lease serialize; read-only work may run concurrently.

## Pi Agent and Codex subscription boundary

- Production embeds a wrapper around pinned Pi `0.82.1` and uses Pi's `ModelRuntime` with the `openai-codex` OAuth provider. Mien never executes an ambient `pi`, `node`, `bun`, or package runner from `PATH`.
- The standalone universal wrapper registers Pi's own statically bundled OAuth loaders on the same pinned `pi-ai` module instance used by `ModelRuntime`. Token derivation and refresh therefore remain available after Bun compilation instead of depending on a source-tree dynamic import.
- The wrapper keeps the existing bounded NDJSON-RPC process envelope, but directly owns Pi's pinned low-level `Agent` and `ModelRuntime`. It exposes only `request_context` and `submit_outcome`; Pi's coding-session resource loader and built-in `read`, `write`, `edit`, `bash`, `grep`, `find`, and `ls` tools are never constructed.
- Pi has no permission sandbox of its own. Therefore the signed Host remains the only trust kernel: it owns TCC, target leases, policy, acquisition, action, verification, and cleanup. The child receives no Accessibility handle, Screen Recording handle, generic filesystem authority, shell, MCP servers, skills, extensions, context files, or project configuration.
- The runtime uses a dedicated owner-only Pi Agent directory. An existing private Pi credential is copied without any global Pi configuration; an existing Codex CLI ChatGPT credential is schema-converted only after its JWT account claim matches the stored account ID. Missing credentials start Pi's official OpenAI Codex device-code OAuth flow; Mien accepts only the exact OpenAI verification origin and code shape and resumes the preserved task after authentication.
- One visible Mien transcript owns one Pi session, and exactly one ledger task may bind to it at a time. An idle conversation may apply a newly selected typed model configuration immediately before its next fresh task binding; an active binding rejects a mid-turn model change. A terminal Host-policy or typed context-preparation rejection releases only the fresh task binding when process continuity is still proven. Cancellation, transport loss, runtime uncertainty, or an invalid session invalidates the whole conversation.
- Every follow-up mechanically renews the original PID, WindowServer window ID, bundle identity, current frame, and public semantics before creating a fresh task. A replacement window fails closed instead of inheriting authority from conversation history.
- Context selection and answer production happen in one Pi tool loop governed by a two-phase runtime state machine. Each provider call exposes exactly one legal tool, Codex receives `tool_choice: required`, parallel calls are disabled, and `submit_outcome` terminates the loop. The model still owns every semantic argument; the runtime owns only protocol order. There is no separate planning prompt, prose parser, retry prompt, or session reconstruction.
- Incomplete phases cross the child boundary as stable numeric RPC codes and become typed Host violations. The Host never parses remote error prose; a returned RPC error proves the child prompt handler is idle, while timeout, cancellation, and transport loss invalidate the conversation.
- A rejected Host tool request aborts the active Pi loop immediately rather than inviting semantic retries. Runtime shutdown awaits graceful termination, escalates to the owned process group, and verifies reaping before releasing ownership, so tests and app exit cannot orphan an Agent helper.
- After each settled Pi prompt (including failures), `conversation-memory.ts` replaces only `request_context` tool-result payloads with an explicit released-evidence receipt. Captured text, base64 images and details are no longer retained for the conversation lifetime. Tool-call IDs/pairing, verbatim user messages, assistant messages and submitted outcomes remain intact. The Agent is told this lifetime rule and requests fresh evidence when later turns need target details. This is not semantic summarization or silent truncation of dialogue; textual dialogue still grows with conversation length and remains subject to the selected model’s context limit.
- The Host owns the visible transcript and task ledger. Standardized thought-presence and tool lifecycle metadata may drive ephemeral process rows, but raw reasoning, tool input/output, agent prose, and exit status never become progress or success truth.
- Pi resolves subscription authentication before initialization, session creation, and each prompt. Its typed OAuth-resolution failure crosses ACP as `-32021`; the Host projects authentication-required readiness and a login action without parsing provider prose or exposing credential diagnostics. The model catalog alone never proves usable authentication. One App-owned login task serves both Settings and the failed-turn action. Device login updates the private Pi store; an existing idle Agent session is retained. On verified connection, the composer resubmits its original immutable turn through `InteractionController` target renewal and a fresh task binding, without replaying a cached snapshot. Dismissal cancels pending recovery; an unrelated or already resumed turn cannot be submitted by a late login completion.
- `Runtime/PiAgent/codex-models.ts` owns account model discovery. Each new ACP session fetches `https://chatgpt.com/backend-api/codex/models` using the OAuth token resolved by Pi, the token's account claim, and the audited `client_version=0.169.0` catalog contract. The request rejects redirects, times out after 10 seconds, and accepts at most 4 MiB / 128 entries. Picker visibility and priority determine the available list and default, matching [Codex's model manager](https://github.com/openai/codex/blob/main/codex-rs/models-manager/src/manager.rs). The adapter validates names, IDs, modalities, context windows, and supported default reasoning. Remote instructions, tools, and routing never enter the Agent.
- Execution and ACP configuration use the same session catalog, including newly advertised model IDs absent from Pi's generated registry. The server supplies each model's default reasoning level. Pi's static model order, private `settings.json` defaults, and another app's model cache are not capability sources. An existing conversation retains its catalog and original default for consistent follow-ups; new conversations and Settings discovery fetch again. No disk cache, static-list fallback, or retry conceals catalog failure. Numeric RPC `-32022` distinguishes catalog failure from authentication `-32021`; diagnostics contain only the classification and HTTP status. Pi's mandatory cost fields are zero bookkeeping values, never displayed prices; its unused Codex output-limit field uses the advertised context ceiling.
- Pi runs in one private ephemeral workspace per visible conversation with no registered filesystem tool and no implicit access to global Pi resources. Every task's evidence artifacts remain separately scoped and are removed at task cleanup; the conversation workspace is removed on dismissal or restart recovery.

## Longview boundary

Longview remains an independent, narrow product:

```text
explicit window target + bounded capture policy
    -> PNG artifact + schema-v2 receipt
```

The product repository does not copy Longview source. The adapter accepts only schema v2, verifies PID/windowID/output identity, and rejects an artifact when restoration is not clean.

## Failure containment

- Agent, ACP, MCP, Longview, or OCR crashes cannot terminate the Host.
- Cancellation starts a short non-cancellable cleanup transaction.
- User input suppresses focus/pointer restoration that would fight the user; the receipt declares the residual state.
- A failed or unverified restoration opens a per-target mutation circuit breaker.
- Startup replay validates every task sequence and removes interrupted local artifacts. It emits `cleanupVerified` only when a prior desktop-restoration fact is durable; unknown restoration remains visibly unclosed in the journal.
- Secure fields, password managers, authentication surfaces, private browsing, protected pixels, and secret sensitivity fail closed.
- Screenshot, AX, OCR, web, chat, and memory content are untrusted data and cannot authorize actions.

## Repository boundary

The public repository contains only Mien. Longview is pinned as an external MIT dependency and enters the product exclusively through its schema-v2 adapter contract. Capture experiments and private evidence are not product source or release inputs.
