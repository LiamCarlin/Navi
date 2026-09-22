import { handle } from "@/lib/http";
import { handleMeteredProxy } from "@/lib/proxy";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

/** POST /v1/jev — body is the exact TypeSafe /v1/systemone body; JSON passthrough. */
export const POST = handle((req) => handleMeteredProxy(req, "jev"));
