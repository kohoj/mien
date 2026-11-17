import { describe, expect, test } from "bun:test";
import {
  enforceCodexToolProtocol,
  TurnProtocolController,
  TurnProtocolError,
} from "./turn-protocol";

describe("TurnProtocolController", () => {
  test("enforces context decision before typed outcome", () => {
    const protocol = new TurnProtocolController();

    protocol.beginTurn();
    expect(protocol.expectedTool()).toBe("request_context");
    protocol.contextResolved();
    expect(protocol.expectedTool()).toBe("submit_outcome");
    protocol.outcomeSubmitted();
    protocol.finishTurn();
    expect(protocol.phase).toBe("idle");
  });

  test("rejects skipped and duplicate phases", () => {
    const protocol = new TurnProtocolController();
    protocol.beginTurn();

    expect(() => protocol.outcomeSubmitted()).toThrow(TurnProtocolError);
    protocol.contextResolved();
    expect(() => protocol.contextResolved()).toThrow(TurnProtocolError);
  });

  test("aborting a failed provider turn leaves the conversation reusable", () => {
    const protocol = new TurnProtocolController();
    protocol.beginTurn();
    protocol.abortTurn();
    protocol.beginTurn();

    expect(protocol.expectedTool()).toBe("request_context");
  });
});

describe("enforceCodexToolProtocol", () => {
  test("keeps exactly one required phase tool and disables parallel calls", () => {
    expect(
      enforceCodexToolProtocol(
        { tool_choice: "required", tools: [{ name: "request_context" }] },
        "request_context",
      ),
    ).toEqual({
      tool_choice: "required",
      tools: [{ name: "request_context" }],
      parallel_tool_calls: false,
    });
  });

  test("fails closed when Codex receives the wrong phase tool", () => {
    expect(() =>
      enforceCodexToolProtocol(
        { tool_choice: "required", tools: [{ name: "submit_outcome" }] },
        "request_context",
      ),
    ).toThrow(TurnProtocolError);
  });
});
