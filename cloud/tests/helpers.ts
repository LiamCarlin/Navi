/** Shared bits for the route-level tests: requests against an in-process handler, cookies. */

export const BASE = "http://localhost:3100";

/** Route tests run on the memory driver with dev features on — set before any handler runs. */
export function useMemoryEnv(extra: Record<string, string | undefined> = {}) {
  const vars: Record<string, string | undefined> = {
    DB_DRIVER: "memory",
    SUPABASE_URL: undefined,
    NEXT_PUBLIC_SUPABASE_URL: undefined,
    SUPABASE_JWT_SECRET: undefined,
    SUPABASE_JWKS_URL: undefined,
    STRIPE_SECRET_KEY: undefined,
    STRIPE_WEBHOOK_SECRET: undefined,
    NAVI_CLOUD_BASE_URL: BASE,
    VERCEL_ENV: undefined,
    ...extra,
  };
  for (const [k, v] of Object.entries(vars)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
}

export function req(path: string, init: RequestInit & { json?: unknown; cookie?: string; bearer?: string; origin?: string | null } = {}): Request {
  const headers = new Headers(init.headers);
  let body = init.body;
  if (init.json !== undefined) {
    headers.set("content-type", "application/json");
    body = JSON.stringify(init.json);
  }
  if (init.cookie) headers.set("cookie", init.cookie);
  if (init.bearer) headers.set("authorization", `Bearer ${init.bearer}`);
  const method = (init.method ?? (body ? "POST" : "GET")).toUpperCase();
  // Browsers send Origin on every non-GET fetch; default to ours unless a test says otherwise.
  if (init.origin !== null && method !== "GET") headers.set("origin", init.origin ?? BASE);
  headers.set("x-real-ip", headers.get("x-real-ip") ?? "203.0.113.9");
  return new Request(`${BASE}${path}`, { method, headers, body });
}

/** `name=value` pairs from a response's Set-Cookie headers (cleared cookies come back as ""). */
export function setCookies(res: Response): Map<string, string> {
  const out = new Map<string, string>();
  for (const line of res.headers.getSetCookie()) {
    const [pair] = line.split(";");
    const i = pair.indexOf("=");
    out.set(pair.slice(0, i), decodeURIComponent(pair.slice(i + 1)));
  }
  return out;
}

export function cookieHeader(cookies: Map<string, string>): string {
  return [...cookies.entries()].filter(([, v]) => v).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join("; ");
}
