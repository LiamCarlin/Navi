/**
 * The real /v1 handlers (proxy + /v1/me) against the memory driver with mock upstreams:
 * kill switch 503, 426, 403 account_disabled, model override, and Jev through the AI Gateway.
 */
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { fromGatewayResponse, toGatewayBody } from "@/lib/admin/jev-gateway";
import { mintAccessToken } from "@/lib/auth";
import { CONFIG_KEY, invalidateConfigCache, makeNotice } from "@/lib/config";
import { getDb, type MemoryDb } from "@/lib/db";
import { handle } from "@/lib/http";
import { invalidateKeyCache } from "@/lib/keys";
import { handleMeteredProxy } from "@/lib/proxy";
import { GET as me } from "@/app/v1/me/route";

const saved = { ...process.env };
let db: MemoryDb;
let token: string;
let n = 0;
const user = () => ({ id: `proxy-user-${n}`, email: `p${n}@example.com` });

beforeAll(() => {
  process.env.DB_DRIVER = "memory";
  delete process.env.SUPABASE_URL;
  delete process.env.SUPABASE_JWT_SECRET;
});
afterAll(() => { process.env = { ...saved }; });

beforeEach(async () => {
  process.env.MOCK_UPSTREAM = "1";
  db = (await getDb()) as MemoryDb;
  db.clear();
  invalidateConfigCache();
  invalidateKeyCache();
  n += 1;
  token = (await mintAccessToken(user())).token;
});
afterEach(() => vi.unstubAllGlobals());

const claude = handle((req) => handleMeteredProxy(req, "claude"));
const jev = handle((req) => handleMeteredProxy(req, "jev"));

function post(path: string, body: unknown, headers: Record<string, string> = {}) {
  return new Request(`http://localhost:3100${path}`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}
const getMe = (headers: Record<string, string> = {}) =>
  me(new Request("http://localhost:3100/v1/me", { headers: { authorization: `Bearer ${token}`, ...headers } }));

const answerBody = { model: "claude-opus-5", max_tokens: 16, messages: [{ role: "user", content: "hi" }] };

describe("gates on the real proxy path", () => {
  it("passes through by default, model untouched", async () => {
    const res = await claude(post("/v1/claude", answerBody, { "x-navi-feature": "answer", "x-navi-version": "0.1.0" }));
    expect(res.status).toBe(200);
    expect((await res.json()).model).toBe("claude-opus-5");
  });

  it("503 feature_disabled when the switch is off", async () => {
    await db.adminSetConfig(CONFIG_KEY, { features: { answers: false } }, "t");
    const res = await claude(post("/v1/claude", answerBody, { "x-navi-feature": "answer" }));
    expect(res.status).toBe(503);
    expect(await res.json()).toMatchObject({ error: "feature_disabled", feature: "answers" });
    // Jev routing is not behind a switch.
    const r2 = await jev(post("/v1/jev", { state: {}, model: "jev-latest", questions: {} }, { "x-navi-feature": "route" }));
    expect(r2.status).toBe(200);
  });

  it("426 upgrade_required below minAppVersion on /v1/*, but /v1/me answers with the config", async () => {
    await db.adminSetConfig(CONFIG_KEY, { minAppVersion: "1.2.0", latestVersion: "1.3.0", downloadURL: "https://buildnavi.com/download", notice: makeNotice("Update please", "warning") }, "t");
    const res = await jev(post("/v1/jev", { state: {}, model: "jev-latest", questions: {} }, { "x-navi-version": "1.0.4" }));
    expect(res.status).toBe(426);
    expect(await res.json()).toMatchObject({ error: "upgrade_required", minAppVersion: "1.2.0", downloadURL: "https://buildnavi.com/download" });

    const m = await getMe({ "x-navi-version": "1.0.4" });
    expect(m.status).toBe(200);
    const body = await m.json();
    expect(body.config).toMatchObject({ minAppVersion: "1.2.0", latestVersion: "1.3.0", downloadURL: "https://buildnavi.com/download", notice: { level: "warning", message: "Update please" } });
    expect(body.config.features).toEqual({ answers: true, tasks: true, voice: true, recall: true });
  });

  it("403 account_disabled on /v1/* and /v1/me", async () => {
    await db.ensureProfile(user().id, user().email, new Date());
    await db.updateProfile(user().id, { disabledAt: new Date().toISOString(), disabledReason: "abuse" });
    const res = await claude(post("/v1/claude", answerBody));
    expect(res.status).toBe(403);
    const body = await res.json();
    expect(body.error).toBe("account_disabled");
    expect(body.message).not.toContain("abuse");
    expect((await getMe()).status).toBe(403);
  });

  it("forces the configured model for the feature (and costs it at that model)", async () => {
    await db.adminSetConfig(CONFIG_KEY, { models: { answer: "claude-haiku-4-5" } }, "t");
    const res = await claude(post("/v1/claude", answerBody, { "x-navi-feature": "answer" }));
    expect((await res.json()).model).toBe("claude-haiku-4-5");
    const task = await claude(post("/v1/claude", answerBody, { "x-navi-feature": "task" }));
    expect((await task.json()).model).toBe("claude-opus-5");
  });
});

describe("Jev via the Vercel AI Gateway", () => {
  it("translates TypeSafe ⇄ gateway shapes", () => {
    expect(toGatewayBody({ state: { a: 1 }, model: "jev-latest", questions: { done: { type: "noul", instructions: "?" }, k: { type: "choice", criteria: { a: "x" } } } })).toEqual({
      state: { a: 1 },
      questions: { done: { type: "boolean", instructions: "?" }, k: { type: "choice", criteria: { a: "x" } } },
    });
    expect(fromGatewayResponse({
      answers: { done: { type: "boolean", probability: 0.91 }, k: { type: "choice", choice: "a", probabilities: { a: 0.7, b: 0.2, c: 0.1 } } },
      providerMetadata: {},
    })).toEqual({
      model: "jev-latest",
      answers: { done: { type: "noul", noul: 0.91 }, k: { type: "choice", choice: "a", probabilities: { a: 0.7, b: 0.2, c: 0.1 }, confidence: 0.5 } },
    });
  });

  it("is used when there is no TypeSafe key but a gateway key", async () => {
    delete process.env.MOCK_UPSTREAM;
    delete process.env.TYPESAFE_API_KEY;
    process.env.AI_GATEWAY_API_KEY = "gw-test-key-0001";
    const fetchMock = vi.fn(async () => Response.json({ answers: { done: { type: "boolean", probability: 0.8 } } }));
    vi.stubGlobal("fetch", fetchMock);
    const res = await jev(post("/v1/jev", { state: {}, model: "jev-latest", questions: { done: { type: "noul", instructions: "done?" } } }));
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ answers: { done: { type: "noul", noul: 0.8 } } });
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toContain("ai-gateway.vercel.sh");
    const headers = init.headers as Record<string, string>;
    expect(headers.authorization).toBe("Bearer gw-test-key-0001");
    expect(headers["ai-model-id"]).toBe("typesafe-ai/jev");
    expect(JSON.parse(String(init.body)).questions.done.type).toBe("boolean");
    delete process.env.AI_GATEWAY_API_KEY;
  });
});
