import { handle } from "@/lib/http";
import { handleMeteredProxy } from "@/lib/proxy";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 120;

/**
 * POST /v1/digest — screen-memory digests. Requires the `recall` entitlement (403 `not_entitled`).
 * Body is an Anthropic /v1/messages body, or `{ provider: "gemini", model?, ...generateContent body }`
 * when GEMINI_API_KEY is configured.
 */
export const POST = handle((req) => handleMeteredProxy(req, "digest"));
