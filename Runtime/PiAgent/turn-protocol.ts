export type TurnProtocolPhase = "idle" | "contextDecision" | "outcome" | "completed";
export type MienToolName = "request_context" | "submit_outcome";

export class TurnProtocolError extends Error {
  constructor(readonly code: string) {
    super(`Mien turn protocol violation: ${code}`);
    this.name = "TurnProtocolError";
  }
}

/**
 * Owns the only legal tool order for one conversation-bound Pi session.
 * The model chooses the typed values, while the runtime makes the protocol
 * sequence deterministic instead of relying on prompt compliance.
 */
export class TurnProtocolController {
  #phase: TurnProtocolPhase = "idle";

  get phase(): TurnProtocolPhase {
    return this.#phase;
  }

  beginTurn(): void {
    if (this.#phase !== "idle") throw new TurnProtocolError("turn_already_active");
    this.#phase = "contextDecision";
  }

  expectedTool(): MienToolName {
    switch (this.#phase) {
      case "contextDecision":
        return "request_context";
      case "outcome":
        return "submit_outcome";
      default:
        throw new TurnProtocolError(`no_tool_expected_in_${this.#phase}`);
    }
  }

  contextResolved(): void {
    this.requirePhase("contextDecision");
    this.#phase = "outcome";
  }

  outcomeSubmitted(): void {
    this.requirePhase("outcome");
    this.#phase = "completed";
  }

  assertCompleted(): void {
    this.requirePhase("completed");
  }

  finishTurn(): void {
    this.assertCompleted();
    this.#phase = "idle";
  }

  abortTurn(): void {
    this.#phase = "idle";
  }

  private requirePhase(expected: TurnProtocolPhase): void {
    if (this.#phase !== expected) {
      throw new TurnProtocolError(`expected_${expected}_found_${this.#phase}`);
    }
  }
}

/** Validates the public Codex request boundary and serializes one phase tool. */
export function enforceCodexToolProtocol(payload: unknown, expectedTool: MienToolName): unknown {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new TurnProtocolError("invalid_provider_payload");
  }
  const body = payload as Record<string, unknown>;
  const tools = Array.isArray(body.tools) ? body.tools : [];
  const toolNames = tools.flatMap((tool) => {
    if (!tool || typeof tool !== "object" || Array.isArray(tool)) return [];
    const name = (tool as Record<string, unknown>).name;
    return typeof name === "string" ? [name] : [];
  });
  if (body.tool_choice !== "required" || toolNames.length !== 1 || toolNames[0] !== expectedTool) {
    throw new TurnProtocolError("provider_tool_contract_mismatch");
  }
  return { ...body, parallel_tool_calls: false };
}
