import { csvField } from "@/lib/admin/format";
import { adminOr404 } from "@/lib/admin/guard";
import { audit } from "@/lib/admin/ops";
import { getDb } from "@/lib/db";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** GET /admin/waitlist/export[?q=] — the waitlist as CSV (admins only; 404 otherwise). */
export async function GET(req: Request): Promise<Response> {
  const who = await adminOr404();
  if (who instanceof Response) return who;
  const q = new URL(req.url).searchParams.get("q") ?? "";
  const db = await getDb();

  const lines = ["email,source,note,created_at,invited_at"];
  const PAGE = 1000;
  let count = 0;
  for (let offset = 0; ; offset += PAGE) {
    const { rows } = await db.adminListWaitlist({ query: q, limit: PAGE, offset });
    for (const w of rows) lines.push([w.email, w.source, w.note, w.createdAt, w.invitedAt].map(csvField).join(","));
    count += rows.length;
    if (rows.length < PAGE) break;
  }
  await audit(db, who.email, "waitlist.export", null, { rows: count, query: q || null });

  const stamp = new Date().toISOString().slice(0, 10);
  return new Response(lines.join("\r\n") + "\r\n", {
    headers: {
      "content-type": "text/csv; charset=utf-8",
      "content-disposition": `attachment; filename="navi-waitlist-${stamp}.csv"`,
      "cache-control": "no-store",
    },
  });
}
