/** Small helpers so every route returns the same JSON error shapes (§3.1). */

export class HttpError extends Error {
  constructor(
    public readonly status: number,
    public readonly body: Record<string, unknown>,
    public readonly headers: Record<string, string> = {},
  ) {
    super(typeof body.error === "string" ? body.error : `HTTP ${status}`);
  }
}

export function json(data: unknown, init: number | ResponseInit = 200): Response {
  const responseInit: ResponseInit = typeof init === "number" ? { status: init } : init;
  const headers = new Headers(responseInit.headers);
  headers.set("content-type", "application/json; charset=utf-8");
  headers.set("cache-control", "no-store");
  return new Response(JSON.stringify(data), { ...responseInit, headers });
}

export function unauthenticated(message = "Sign in to Navi to continue."): HttpError {
  return new HttpError(401, { error: "unauthenticated", message }, { "www-authenticate": "Bearer" });
}

export function badRequest(message: string, extra: Record<string, unknown> = {}): HttpError {
  return new HttpError(400, { error: "bad_request", message, ...extra });
}

export function rateLimited(retryAfterSeconds: number): HttpError {
  return new HttpError(
    429,
    { error: "rate_limited", retryAfterSeconds },
    { "retry-after": String(Math.max(1, Math.ceil(retryAfterSeconds))) },
  );
}

/** Wraps a handler so thrown HttpErrors become responses and anything else a clean 500. */
export function handle(fn: (req: Request) => Promise<Response>): (req: Request) => Promise<Response> {
  return async (req) => {
    try {
      return await fn(req);
    } catch (e) {
      if (e instanceof HttpError) return json(e.body, { status: e.status, headers: e.headers });
      console.error(`[navi-cloud] ${req.method} ${new URL(req.url).pathname} failed:`, e);
      return json({ error: "internal", message: "Something went wrong on Navi's side. Try again." }, 500);
    }
  };
}

export async function readJson<T = Record<string, unknown>>(req: Request): Promise<T> {
  const text = await req.text();
  return parseJson<T>(text);
}

export function parseJson<T = Record<string, unknown>>(text: string): T {
  if (!text.trim()) throw badRequest("Expected a JSON body.");
  try {
    return JSON.parse(text) as T;
  } catch {
    throw badRequest("Body is not valid JSON.");
  }
}

/** Best-effort client IP behind Vercel / any proxy. */
export function clientIp(req: Request): string {
  const h = req.headers;
  return (
    h.get("x-real-ip") ??
    h.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    h.get("cf-connecting-ip") ??
    "unknown"
  );
}
