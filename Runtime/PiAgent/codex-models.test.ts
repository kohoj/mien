import { describe, expect, test } from "bun:test";
import { CodexCatalogError, loadCodexCatalog, parseCodexCatalog } from "./codex-models";

const model = (slug: string, priority: number, visibility = "list") => ({
  slug, display_name: `Name ${slug}`, description: "Server description", priority, visibility,
  default_reasoning_level: "low", supported_reasoning_levels: [{ effort: "low" }],
  context_window: 500_000, input_modalities: ["text", "image"],
});
const token = `header.${Buffer.from(JSON.stringify({
  "https://api.openai.com/auth": { chatgpt_account_id: "test-account" },
})).toString("base64url")}.signature`;
const respond = (body: unknown, status = 200) => (async () => Response.json(body, { status })) as typeof fetch;

describe("account model catalog", () => {
  test("server priority chooses default and new model IDs need no local registry entry", () => {
    const catalog = parseCodexCatalog({ models: [
      model("older", 8), model("hidden", 0, "hide"), model("unlisted", 0, "none"), model("future-model", 1),
    ] });
    expect(catalog.map((m) => m.id)).toEqual(["future-model", "older"]);
    expect(catalog[0]).toMatchObject({ name: "Name future-model", defaultReasoningEffort: "low", contextWindow: 500_000 });
  });

  test("empty, duplicate, malformed and unsupported capability catalogs fail closed", () => {
    for (const models of [[], [model("hidden", 1, "hide")], [model("same", 1), model("same", 2)],
      [{ ...model("bad", 1), context_window: null }], [{ ...model("bad", 1), priority: "1" }],
      [{ ...model("bad", 1), default_reasoning_level: "unsupported" }],
      [{ ...model("bad", 1), input_modalities: ["video"] }]]) {
      expect(() => parseCodexCatalog({ models })).toThrow(CodexCatalogError);
    }
  });

  test("catalog cannot replace product instructions, request destination or tools", () => {
    const catalog = parseCodexCatalog({ models: [{ ...model("remote", 1),
      base_url: "https://untrusted.invalid", base_instructions: "untrusted instructions", tools: ["shell"],
    }] });
    expect(catalog[0].baseUrl).toBe("https://chatgpt.com/backend-api");
    expect(catalog[0]).not.toHaveProperty("base_instructions");
    expect(catalog[0]).not.toHaveProperty("tools");
  });

  test("fetch uses the resolved account credential and reloads instead of reusing stale data", async () => {
    let calls = 0;
    const request = (async (url: string, init: RequestInit) => {
      expect(url).toStartWith("https://chatgpt.com/backend-api/codex/models?client_version=");
      const headers = new Headers(init.headers);
      expect(headers.get("authorization")).toBe(`Bearer ${token}`);
      expect(headers.get("chatgpt-account-id")).toBe("test-account");
      expect(init.redirect).toBe("error");
      expect(init.signal).toBeInstanceOf(AbortSignal);
      return Response.json({ models: [model(`revision-${++calls}`, 1)] });
    }) as typeof fetch;
    expect((await loadCodexCatalog(token, request))[0].id).toBe("revision-1");
    expect((await loadCodexCatalog(token, request))[0].id).toBe("revision-2");
  });

  test("HTTP, authentication, transport and schema errors remain distinct without leaking bodies", async () => {
    for (const [status, kind] of [[401, "authentication"], [403, "response"], [429, "response"], [503, "response"]] as const) {
      await expect(loadCodexCatalog(token, respond({ secret: "do not expose" }, status)))
        .rejects.toMatchObject({ kind, status });
    }
    await expect(loadCodexCatalog("invalid", respond({}))).rejects.toMatchObject({ kind: "authentication" });
    await expect(loadCodexCatalog(token, respond({ models: "bad" }))).rejects.toMatchObject({ kind: "schema" });
    await expect(loadCodexCatalog(token, (async () => { throw new Error("private error"); }) as typeof fetch))
      .rejects.toMatchObject({ kind: "transport", message: "Codex model catalog transport" });
  });

  test("bounds response bytes even without content-length", async () => {
    const request = (async () => new Response("x".repeat(4 * 1024 * 1024 + 1))) as typeof fetch;
    await expect(loadCodexCatalog(token, request)).rejects.toMatchObject({ kind: "response" });
  });
});
