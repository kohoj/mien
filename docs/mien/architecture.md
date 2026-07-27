# Mien — architecture

Status: working developer preview. The ownership boundaries below are implemented; the remaining production gates are tracked separately in `release-status.md`.

## Product invariant

The product is a local macOS trust kernel for spatial intent, not a mouse replacement and not a Codex chat shell.

```text
pointer / selection / keyboard focus
    -> immutable target lease
    -> minimum sufficient context
    -> user-owned Codex through ACP
    -> typed capability proposal
    -> host policy and execution
    -> postcondition verification
    -> recovery receipt and undo
```

The agent may propose intent and plans. It never owns target identity, context authorization, desktop privileges, execution authority, or the fact that an operation succeeded.

## Three buses

### Reference bus

`Global shortcut -> pointer/window/AX hit-test -> InvocationSnapshot -> TargetLease`

It freezes the target before the product overlay becomes key. `PID + WindowServer windowID + frame + AX fingerprint + userInputEpoch` are the minimum stable identity. Window title is mutable metadata and never a lease key.

### Context bus

`selection -> AX element/subtree -> connector -> region/window pixels -> Longview -> local OCR -> scoped memory -> visual fallback`

Users choose semantic scope such as “this message”, “this conversation”, or “more history”. The Host chooses the acquisition mechanism. Every artifact carries provenance, sensitivity, trust level, TTL, and a target lease.

### Execution bus

`Codex proposal -> capability grant -> typed action -> verifier -> recovery -> receipt`

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
└── codex-acp child (network/model, no desktop capability handles)
    └── Codex App Server
```

The Host is the only durable TCC identity. ACP and MCP children do not receive Accessibility or Screen Recording handles. A signed Host may initially keep sensing and deterministic action in one process to avoid fragmented TCC prompts; agent isolation is mandatory from day one.

## Modules and ownership

| Module | Owns | Must not own |
|---|---|---|
| `InteractionShell` | hotkey, semantic halo, composer, task capsule, accessibility UI | desktop capture, Codex, policy |
| `InvocationKernel` | atomic target freeze, coordinates, WindowServer/AX identity | overlay UI, mutation |
| `MienContracts` | wire-stable immutable contracts | providers, side effects |
| `ContextKernel` | provider ladder, budgets, coherence, omissions | direct UI, agent sessions |
| `ProviderAdapters` | narrow provider translation, including Longview schema v2 | product policy, generic automation |
| `PolicyKernel` | deterministic subject/operation/sensitivity/destination decisions | prompt interpretation |
| `TaskRuntime` | event-sourced lifecycle and terminal truth | UI phrasing, hidden mutable state |
| `ACPGateway` | ACP v1 framing, negotiation, supervised process lifecycle | desktop capabilities |
| `ActionKernel` | typed mutations, compare-and-swap, inverse operations | general-purpose click/type/shell |
| `DesktopActionAdapters` | exact AX field read/write/read-back/rollback/undo transaction | send, click, key events, clipboard, generic AX action |
| `MemoryKernel` | namespaced claims, provenance, candidates, expiry | raw always-on screen recording |

## Core contracts

### `InvocationSnapshot` and `TargetLease`

Captured at keydown before any product window can affect focus. A lease expires, is revalidated before mutation, and fails closed when PID, windowID, AX fingerprint, frame tolerance, Space, or user input epoch changes.

### `ContextArtifact` and `ContextManifest`

Raw content is stored as a private immutable artifact. The manifest contains ordered references, included and omitted scope, redactions, destination decision, coherence status, and a digest. Ledger events keep digests and provenance instead of duplicating private payloads.

### `TaskCapsule`

The unit of agent work: intent, target lease, manifest, desired outcome, allowed action classes, approval policy, deadline, and ACP session binding.

### `CapabilityGrant`

A short-lived, exact-tool, exact-action, maximum-scope, bounded-use authorization tied to one task and one target lease. High-risk grants require approval provenance.

### `MutationReceipt` and `RecoveryReceipt`

A mutation is successful only when its postcondition is independently verified and all affected environment facets are clean. “Tool call returned success” is never a product success state.

## Task lifecycle

```text
created
  -> targetLocked
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

1. Show the composer from the frozen target; semantic refinement may complete asynchronously.
2. Prefer the smallest provider that can satisfy the semantic scope.
3. Never start a continuous screen stream while idle.
4. Use one-shot targeted capture before Longview.
5. Longview is the bounded-history provider; its receipt must prove motion, overlap, and restoration.
6. OCR/VLM output is untrusted derived data and cannot widen permission.
7. Memory retrieval is another manifest artifact and remains visible to the user.
8. Dynamic content requires a coherence group; inconsistent captures are retried or declared partial.

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

## ACP and Codex boundary

- Production targets stable ACP protocol v1 and negotiates optional capability use.
- `codex-acp` is a pinned, signed, notarized nested runtime; production never executes `npx -y`.
- The compatible Codex binary ships with the adapter. It runs from a dedicated private Codex home and does not implicitly inherit global MCP, skills, history, or configuration. Existing users get a one-time, owner-only projection of `auth.json`; the source is symlink-safe, size-bounded, private, and never logged. When credentials are absent, the Host runs the bundled official device-auth flow, accepts only the exact OpenAI verification origin and code shape, and resumes the preserved task after authentication. Arbitrary binaries found on `PATH` are never trusted.
- One warm supervised process supports multiple task sessions. A task owns one ACP session; turns within it are serial.
- The Host owns task history because ACP-created sessions are not a reliable product UI surface in Codex Desktop.
- `APP_SERVER_LOGS` is forbidden because it can persist prompt, context, and tool output.
- Codex runs in a private task workspace, read-only by default, with no implicit access to the user's home directory or global MCP set.

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
