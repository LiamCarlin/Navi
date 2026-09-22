import { createClient } from "@supabase/supabase-js";
import { createHash } from "node:crypto";
import { appendFile, readFile } from "node:fs/promises";
import path from "node:path";

export type WaitlistEntry = {
  email: string;
  source: string;
  note: string | null;
  created_at: string;
};

export type InsertResult = "created" | "exists";

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

export function normalizeEmail(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const email = raw.trim().toLowerCase();
  if (email.length > 254 || !EMAIL_RE.test(email)) return null;
  return email;
}

export function cleanNote(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const note = raw.trim().slice(0, 500);
  return note.length ? note : null;
}

/** Where the signup came from: `hero`, `sticky`, `mid-02`, `pricing-pro`, … optionally with `.ref-<id>`. */
export function cleanSource(raw: unknown, ref?: unknown): string {
  let s = typeof raw === "string" ? raw.trim().slice(0, 40) : "";
  if (!/^[\w.-]+$/.test(s)) s = "site";
  if (typeof ref === "string") {
    const r = ref.trim().slice(0, 16);
    if (/^[a-z0-9]+$/i.test(r)) s = `${s}.ref-${r.toLowerCase()}`;
  }
  return s.slice(0, 64);
}

/** A short, stable id for an email so a signup can share a `?ref=` link without exposing the address. */
export function refId(email: string): string {
  return createHash("sha256").update(email).digest("hex").slice(0, 8);
}

/** Path of the dev fallback file: `web/.waitlist.local.jsonl` (gitignored). */
export const LOCAL_FILE = path.join(process.cwd(), ".waitlist.local.jsonl");

function supabase() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_KEY;
  if (!url || !key) return null;
  return createClient(url, key, { auth: { persistSession: false } });
}

/**
 * Inserts into Supabase `waitlist(email, source, note, created_at)` when configured,
 * otherwise appends a JSON line to the local file. Dedupes on email either way.
 */
export async function addToWaitlist(entry: WaitlistEntry): Promise<InsertResult> {
  const client = supabase();
  if (client) {
    const { error } = await client.from("waitlist").insert(entry);
    if (!error) return "created";
    // 23505 = unique_violation (the table has a unique index on email).
    if (error.code === "23505") return "exists";
    throw new Error(`supabase: ${error.message}`);
  }
  return appendLocal(entry);
}

/** How many people are on the list. Cached for 60 s per server instance. */
let countCache: { n: number; at: number } | null = null;
export async function countWaitlist({ fresh = false } = {}): Promise<number> {
  if (!fresh && countCache && Date.now() - countCache.at < 60_000) return countCache.n;
  const client = supabase();
  let n: number;
  if (client) {
    const { count, error } = await client.from("waitlist").select("*", { count: "exact", head: true });
    if (error) throw new Error(`supabase: ${error.message}`);
    n = count ?? 0;
  } else {
    n = (await readLocal()).length;
  }
  countCache = { n, at: Date.now() };
  return n;
}

async function readLocal(): Promise<Partial<WaitlistEntry>[]> {
  let existing = "";
  try {
    existing = await readFile(LOCAL_FILE, "utf8");
  } catch {
    return [];
  }
  const rows: Partial<WaitlistEntry>[] = [];
  for (const line of existing.split("\n")) {
    if (!line.trim()) continue;
    try {
      rows.push(JSON.parse(line) as Partial<WaitlistEntry>);
    } catch {
      // ignore malformed lines
    }
  }
  return rows;
}

async function appendLocal(entry: WaitlistEntry): Promise<InsertResult> {
  for (const row of await readLocal()) {
    if (row.email === entry.email) return "exists";
  }
  await appendFile(LOCAL_FILE, JSON.stringify(entry) + "\n", "utf8");
  return "created";
}
