# Repository guidance

## Product invariant

Mien is a native macOS intelligence layer with a strict trust kernel. The agent proposes; the signed Host owns target identity, context authority, policy, execution, verification, and recovery.

## Ownership

- Keep contracts immutable, Codable, Sendable, and fail-closed.
- Keep platform mechanisms out of `HostRuntime`; it composes deep modules only.
- Keep ACP and MCP children free of TCC handles and generic desktop capabilities.
- Keep Longview independent. Integrate only through schema-v2 adapter contracts.
- Never make agent prose, process exit status, or tool return values the source of task success.

## Required checks

Run `scripts/verify-mien.sh` after cross-module work. Run the opt-in live ACP smoke tests when changing process framing, negotiation, prompt projection, or runtime packaging.

## Engineering bar

Prefer one explicit owner and a small stable interface. Reject hidden fallbacks, ambient authority, duplicated configuration, unbounded work, silent degradation, and UI that claims more than the ledger proves. Preserve unrelated user files and historical evidence.
