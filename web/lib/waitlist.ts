import { createClient } from "@supabase/supabase-js";
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

export function cleanSource(raw: unknown): string {
  if (typeof raw !== "string") return "site";
  const s = raw.trim().slice(0, 64);
  return /^[\w.-]+$/.test(s) ? s : "site";
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

async function appendLocal(entry: WaitlistEntry): Promise<InsertResult> {
  let existing = "";
  try {
    existing = await readFile(LOCAL_FILE, "utf8");
  } catch {
    // first entry
  }
  for (const line of existing.split("\n")) {
    if (!line.trim()) continue;
    try {
      const row = JSON.parse(line) as Partial<WaitlistEntry>;
      if (row.email === entry.email) return "exists";
    } catch {
      // ignore malformed lines
    }
  }
  await appendFile(LOCAL_FILE, JSON.stringify(entry) + "\n", "utf8");
  return "created";
}
