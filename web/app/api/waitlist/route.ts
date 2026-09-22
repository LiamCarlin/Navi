import { NextResponse } from "next/server";
import { addToWaitlist, cleanNote, cleanSource, countWaitlist, normalizeEmail, refId } from "@/lib/waitlist";

export const runtime = "nodejs";

/**
 * POST /api/waitlist  { email, note?, source?, ref? }
 *   201 { ok: true, status: "created", position, ref }   new email
 *   200 { ok: true, status: "exists",  position, ref }   already on the list
 *   400 { error }                                        bad email / body
 *   500 { error }                                        storage failure
 * `position` is the list size after the insert; `ref` is the signup's share id for `?ref=`.
 * Older clients that only read `ok`/`status` keep working.
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
      source: cleanSource(body.source, body.ref),
      note: cleanNote(body.note),
      created_at: new Date().toISOString(),
    });
    let position: number | null = null;
    try {
      position = await countWaitlist({ fresh: true });
    } catch {
      // the signup succeeded; the position is a nicety
    }
    return NextResponse.json({ ok: true, status, position, ref: refId(email) }, { status: status === "created" ? 201 : 200 });
  } catch (err) {
    console.error("[waitlist]", err instanceof Error ? err.message : err);
    return NextResponse.json({ error: "Couldn't save that right now. Try again in a minute." }, { status: 500 });
  }
}

export function GET() {
  return NextResponse.json({ error: "Method not allowed" }, { status: 405 });
}
