import { expect, test } from "bun:test";
import { releaseCompletedEvidence } from "./conversation-memory";

test("completed turns release captured text and images without losing dialogue or tool pairing", () => {
  const user = { role: "user", content: "  verbatim\nrequest  ", timestamp: 1 } as const;
  const evidence = {
    role: "toolResult" as const, toolCallId: "context-1", toolName: "request_context", isError: false,
    content: [{ type: "image" as const, data: "x".repeat(4 * 1024 * 1024), mimeType: "image/png" },
      { type: "text" as const, text: "private captured text" }],
    details: { captured: "private" }, timestamp: 2,
  };
  const result = { ...evidence, toolCallId: "outcome-1", toolName: "submit_outcome", content: [{ type: "text" as const, text: "accepted" }] };
  const released = releaseCompletedEvidence([user, evidence, result]);
  expect(released[0]).toBe(user);
  expect(released[2]).toBe(result);
  expect(released[1]).toMatchObject({ role: "toolResult", toolCallId: "context-1", isError: false });
  expect(JSON.stringify(released[1])).not.toContain("private");
  expect(JSON.stringify(released[1]).length).toBeLessThan(600);
  expect(evidence.content[0].data?.length).toBe(4 * 1024 * 1024); // no mutation during an active turn
  expect(releaseCompletedEvidence(released)).toEqual(released);
});

test("failed context responses also release their evidence", () => {
  const released = releaseCompletedEvidence([{
    role: "toolResult", toolCallId: "context-failed", toolName: "request_context",
    content: [{ type: "text", text: "partial private capture" }], isError: true, timestamp: 1,
  }]);
  expect(released[0]).toMatchObject({ isError: true, toolCallId: "context-failed" });
  expect(JSON.stringify(released)).not.toContain("partial private capture");
});
