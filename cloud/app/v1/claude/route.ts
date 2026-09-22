import { handle } from "@/lib/http";
import { handleMeteredProxy } from "@/lib/proxy";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
/** Long agent turns stream for minutes; Vercel Pro allows up to 300 s (800 s on Fluid). */
export const maxDuration = 300;

/** POST /v1/claude — body is the exact Anthropic /v1/messages body; SSE streamed through when `stream: true`. */
export const POST = handle((req) => handleMeteredProxy(req, "claude"));
