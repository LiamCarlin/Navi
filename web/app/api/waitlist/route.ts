import { NextResponse } from "next/server";
import { addToWaitlist, cleanNote, cleanSource, normalizeEmail } from "@/lib/waitlist";

export const runtime = "nodejs";

/**
 * POST /api/waitlist  { email, note?, source? }
 *   201 { ok: true, status: "created" }   new email
 *   200 { ok: true, status: "exists" }    already on the list
 *   400 { error }                         bad email / body
 *   500 { error }                         storage failure
 */
export async function POST(req: Request) {
  let body: Record<string, unknown>;
  try {
    body = (await req.json()) as Record<string, unknown>;
  } catch {
    return NextResponse.json({ error: "Send a JSON body." }, { status: 400 });
  }

  const email = normalizeEmail(body.email);
  if (!email) {
    return NextResponse.json({ error: "That doesn't look like an email address." }, { status: 400 });
  }

  try {
    const status = await addToWaitlist({
      email,
      source: cleanSource(body.source),
      note: cleanNote(body.note),
      created_at: new Date().toISOString(),
    });
    return NextResponse.json({ ok: true, status }, { status: status === "created" ? 201 : 200 });
  } catch (err) {
    console.error("[waitlist]", err instanceof Error ? err.message : err);
    return NextResponse.json({ error: "Couldn't save that right now. Try again in a minute." }, { status: 500 });
  }
}

export function GET() {
  return NextResponse.json({ error: "Method not allowed" }, { status: 405 });
}
