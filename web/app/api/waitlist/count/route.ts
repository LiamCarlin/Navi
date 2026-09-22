import { NextResponse } from "next/server";
import { countWaitlist } from "@/lib/waitlist";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** GET /api/waitlist/count → { count }. Cached 60 s server-side; the page hides it under 25. */
export async function GET() {
  try {
    const count = await countWaitlist();
    return NextResponse.json({ count }, { headers: { "Cache-Control": "public, s-maxage=60, stale-while-revalidate=300" } });
  } catch (err) {
    console.error("[waitlist/count]", err instanceof Error ? err.message : err);
    return NextResponse.json({ error: "Unavailable" }, { status: 500 });
  }
}
