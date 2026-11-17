import type { Model } from "./node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/types.js";
import type { OpenAICodexResponsesOptions } from "./node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/api/openai-codex-responses.js";

// Codex's catalog requires a compatible client version. This is the audited
// catalog wire contract, not Mien's version or a model release identifier.
const catalogURL = "https://chatgpt.com/backend-api/codex/models?client_version=0.169.0";
const maximumBytes = 4 * 1024 * 1024;

export class CodexCatalogError extends Error {
  constructor(readonly kind: "authentication" | "transport" | "response" | "schema" | "empty", readonly status?: number) {
    super(`Codex model catalog ${kind}${status === undefined ? "" : ` (${status})`}`);
  }
}

export type CodexModel = Model<"openai-codex-responses"> & {
  description: string;
  defaultReasoningEffort: NonNullable<OpenAICodexResponsesOptions["reasoningEffort"]>;
};

function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new CodexCatalogError("schema");
  return value as Record<string, unknown>;
}

function text(value: unknown, maximumLength: number): string {
  if (typeof value !== "string" || !value.trim() || value.length > maximumLength || /[\u0000-\u001f]/.test(value)) {
    throw new CodexCatalogError("schema");
  }
  return value;
}

/** Only server-advertised picker entries become executable models. Do not
 * intersect with Pi's generated registry: that would hide new server models.
 * Catalog instructions, tools, routing, and other executable policy are ignored.
 */
export function parseCodexCatalog(value: unknown): readonly CodexModel[] {
  const entries = object(value).models;
  if (!Array.isArray(entries) || entries.length > 128) throw new CodexCatalogError("schema");
  const ids = new Set<string>();
  const visible: Array<{ priority: number; model: CodexModel }> = [];
  for (const raw of entries) {
    const entry = object(raw);
    if (entry.visibility === "hide" || entry.visibility === "none") continue;
    if (entry.visibility !== "list") throw new CodexCatalogError("schema");
    const id = text(entry.slug, 128);
    if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(id) || ids.has(id)) throw new CodexCatalogError("schema");
    ids.add(id);
    const name = text(entry.display_name, 160);
    const description = text(entry.description, 2048);
    const priority = entry.priority;
    const contextWindow = entry.context_window;
    const input = entry.input_modalities;
    const defaultReasoningEffort = text(entry.default_reasoning_level, 32);
    const supportedDefaults = ["none", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
    const efforts = entry.supported_reasoning_levels;
    if (!Number.isSafeInteger(priority) || !Number.isSafeInteger(contextWindow) || (contextWindow as number) <= 0
      || !Array.isArray(input) || !input.includes("text") || input.some((v) => v !== "text" && v !== "image")
      || !supportedDefaults.some((effort) => effort === defaultReasoningEffort)
      || !Array.isArray(efforts) || !efforts.some((v) => object(v).effort === defaultReasoningEffort)) {
      throw new CodexCatalogError("schema");
    }
    visible.push({ priority: priority as number, model: {
      id, name, description,
      defaultReasoningEffort: defaultReasoningEffort as CodexModel["defaultReasoningEffort"],
      api: "openai-codex-responses", provider: "openai-codex",
      baseUrl: "https://chatgpt.com/backend-api", reasoning: true,
      input: [...new Set(input)] as ("text" | "image")[], contextWindow: contextWindow as number,
      // The subscription catalog has no per-token prices or output cap. Pi
      // requires these fields; no price is presented and the Codex transport
      // does not send maxTokens. Use the advertised context as a ceiling.
      maxTokens: contextWindow as number,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    } });
  }
  if (visible.length === 0) throw new CodexCatalogError("empty");
  return visible.sort((a, b) => a.priority - b.priority).map(({ model }) => model);
}

/** Fresh, account-scoped snapshot. No disk cache or static fallback. Pi remains
 * the credential owner; the caller supplies its resolved/refreshed OAuth token.
 */
export async function loadCodexCatalog(token: string, request: typeof fetch = fetch): Promise<readonly CodexModel[]> {
  let accountID: string;
  try {
    const claims = object(JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8")));
    accountID = text(object(claims["https://api.openai.com/auth"]).chatgpt_account_id, 256);
  } catch {
    throw new CodexCatalogError("authentication");
  }
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000);
  try {
    const response = await request(catalogURL, {
      headers: { Authorization: `Bearer ${token}`, "ChatGPT-Account-ID": accountID,
        originator: "pi", "User-Agent": "Mien", Accept: "application/json" },
      redirect: "error", signal: controller.signal,
    });
    if (response.status === 401) throw new CodexCatalogError("authentication", response.status);
    if (!response.ok) throw new CodexCatalogError("response", response.status);
    if (!response.body) throw new CodexCatalogError("schema");
    const reader = response.body.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > maximumBytes) throw new CodexCatalogError("response");
        chunks.push(value);
      }
    } finally {
      await reader.cancel();
    }
    let body: unknown;
    try { body = JSON.parse(Buffer.concat(chunks).toString("utf8")); }
    catch { throw new CodexCatalogError("schema"); }
    return parseCodexCatalog(body);
  } catch (error) {
    if (error instanceof CodexCatalogError) throw error;
    throw new CodexCatalogError("transport");
  } finally {
    controller.abort();
    clearTimeout(timeout);
  }
}
