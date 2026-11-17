# Repository guidance

## Product invariant

Mien is a native macOS intelligence layer with a strict trust kernel. The Agent alone interprets user input and proposes the evidence and outcome it needs. The signed Host never classifies or infers intent; it owns target identity, context authority, policy, acquisition, execution, verification, and recovery.

## Ownership

- Keep contracts immutable, Codable, Sendable, and fail-closed.
- Keep platform mechanisms out of `HostRuntime`; it composes deep modules only.
- Keep Pi, ACP-transport, and MCP children free of TCC handles and generic desktop capabilities.
- Keep Longview independent. Integrate only through schema-v2 adapter contracts.
- Pass every submitted user turn verbatim to one conversation-bound Agent session, with exactly one task binding active at a time. Each turn must renew the exact target and own a fresh ledger task, lease, typed context decision, validation, and cleanup; an evidence-requesting decision additionally owns a fresh manifest. Accept only typed context decisions and typed outcomes; never add keyword, regex, classifier, scope-default, or prose fallback paths in Host code.
- Treat Accessibility, the current frame, and visual history as evidence adapters selected by the Agent. The Host may validate and deny a request, but must not replace it with a semantically guessed request.
- Derive onboarding readiness live from Agent connection and public TCC status. A persisted introduction flag may control first-run presentation, but must never become capability truth.
- Never make agent prose, process exit status, or tool return values the source of task success.
- Project process UI only from typed Host lifecycle facts and standardized Pi activity metadata. Never render raw reasoning, tool input/output, or unvalidated agent text as progress.

## Required checks

Run `scripts/verify-mien.sh` after cross-module work. Run the opt-in live Pi Agent smoke tests when changing process framing, tool negotiation, prompt projection, or runtime packaging.
Use `script/build_and_run.sh` as the sole local build, install, and launch entrypoint; it delegates the canonical assembly and exact-process installation paths and powers the Codex Run action.

## Engineering bar

Prefer one explicit owner and a small stable interface. Reject hidden fallbacks, ambient authority, duplicated configuration, unbounded work, silent degradation, and UI that claims more than the ledger proves. Preserve unrelated user files and historical evidence.
