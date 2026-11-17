import type { AgentMessage } from "@earendil-works/pi-agent-core";

const releasedEvidence =
  "Evidence from this completed turn has been released. The conversation's user messages and submitted outcomes remain available. Request fresh evidence through request_context when a later turn needs target details; prior evidence never grants current target authority.";

/** Evidence is leased to one Host task, not owned by the conversation. Preserve
 * tool-call/result pairing and every user/assistant message, but release captured
 * text and base64 images after the Agent has settled (including failed turns).
 * This is mechanical lifetime management, not semantic conversation summarizing.
 */
export function releaseCompletedEvidence(messages: readonly AgentMessage[]): AgentMessage[] {
  return messages.map((message) => {
    if (message.role !== "toolResult" || message.toolName !== "request_context") return message;
    return { ...message, content: [{ type: "text", text: releasedEvidence }], details: undefined };
  });
}
