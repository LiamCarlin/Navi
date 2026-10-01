"use server";

/**
 * Server actions behind every console form. Each one: requireAdmin() (404 otherwise) →
 * the op in lib/admin/ops.ts (which writes the audit row) → redirect back with a flash.
 */

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { CONFIG_KEY, FEATURE_SWITCHES, makeNotice, MODEL_FEATURES, normalizeConfig, type ProductConfig, type QuotaOverride } from "@/lib/config";
import { getDb } from "@/lib/db";
import { env } from "@/lib/env";
import { withFlash } from "@/lib/admin/format";
import { requireAdmin } from "@/lib/admin/guard";
import * as ops from "@/lib/admin/ops";
import { isVendorProvider, PROVIDER_INFO } from "@/lib/keys";
import { TIERS } from "@/lib/plans";

type Ctx = { actor: string; db: Awaited<ReturnType<typeof getDb>> };

/** Runs an op and redirects to `back` with ?ok= or ?err=. `redirect` must stay outside the try. */
async function run(back: string, op: (ctx: Ctx) => Promise<string | void>): Promise<never> {
  const who = await requireAdmin();
  const db = await getDb();
  let ok = true;
  let message = "Saved.";
  try {
    message = (await op({ actor: who.email, db })) ?? message;
  } catch (e) {
    ok = false;
    message = e instanceof Error ? e.message : "Something went wrong.";
    if (!(e instanceof ops.AdminInputError)) console.error("[navi-admin] action failed:", message);
  }
  revalidatePath("/admin", "layout");
  redirect(withFlash(back, ok, message));
}

const str = (f: FormData, k: string) => String(f.get(k) ?? "").trim();
const userBack = (f: FormData) => `/admin/users/${encodeURIComponent(str(f, "userId"))}`;

// MARK: - Users

export async function setTierOverrideAction(f: FormData) {
  await run(userBack(f), async ({ db, actor }) => {
    const tier = str(f, "tier");
    await ops.setTierOverride(db, actor, str(f, "userId"), tier || null);
    return tier && tier !== "none" ? `Tier override set to ${tier}.` : "Tier override cleared.";
  });
}

export async function grantEntitlementAction(f: FormData) {
  await run(userBack(f), async ({ db, actor }) => {
    const exp = str(f, "expiresAt");
    await ops.grantEntitlement(db, actor, str(f, "userId"), str(f, "key"), exp ? `${exp}T23:59:59Z` : null);
    return `Granted ${str(f, "key")}${exp ? ` until ${exp}` : ""}.`;
  });
}

export async function revokeEntitlementAction(f: FormData) {
  await run(userBack(f), async ({ db, actor }) => {
    await ops.revokeEntitlement(db, actor, str(f, "userId"), str(f, "key"));
    return `Revoked ${str(f, "key")}.`;
  });
}

export async function extendTrialAction(f: FormData) {
  await run(userBack(f), async ({ db, actor }) => {
    const until = await ops.extendTrial(db, actor, str(f, "userId"), Number(str(f, "days")));
    return `Trial now ends ${until.slice(0, 10)}.`;
  });
}

export async function resetQuotaAction(f: FormData) {
  await run(userBack(f), async ({ db, actor }) => {
    const scope = str(f, "scope") === "month" ? "month" : "day";
    await ops.resetQuota(db, actor, str(f, "userId"), scope);
    return scope === "day" ? "Today's quota reset." : "This month's tasks reset.";
  });
}

export async function setDisabledAction(f: FormData) {
  await run(userBack(f), async ({ db, actor }) => {
    const disable = str(f, "disable") === "1";
    await ops.setDisabled(db, actor, str(f, "userId"), disable, str(f, "reason") || null);
    return disable ? "Account disabled — every /v1 call now returns 403." : "Account enabled.";
  });
}

export async function signOutAllAction(f: FormData) {
  await run(userBack(f), async ({ db, actor }) => {
    await ops.signOutEverywhere(db, actor, str(f, "userId"));
    return "Signed out everywhere (refresh tokens revoked; current access tokens expire within an hour).";
  });
}

export async function deleteUserAction(f: FormData) {
  const userId = str(f, "userId");
  let deleted = false;
  const who = await requireAdmin();
  const db = await getDb();
  let message = "Deleted.";
  try {
    await ops.deleteUser(db, who.email, userId, str(f, "confirmEmail"));
    deleted = true;
    message = `Deleted ${str(f, "confirmEmail")}.`;
  } catch (e) {
    message = e instanceof Error ? e.message : "Delete failed.";
  }
  revalidatePath("/admin", "layout");
  redirect(deleted ? withFlash("/admin/users", true, message) : withFlash(`/admin/users/${encodeURIComponent(userId)}`, false, message));
}

// MARK: - Keys

function provider(f: FormData) {
  const p = str(f, "provider");
  if (!isVendorProvider(p)) throw new ops.AdminInputError("Unknown provider.");
  return p;
}

export async function setKeyAction(f: FormData) {
  await run("/admin/keys", async ({ db, actor }) => {
    const p = provider(f);
    await ops.setKey(db, actor, p, f.get("key"), str(f, "rotating") === "1");
    return `${PROVIDER_INFO[p].label} key stored (encrypted). The proxy uses it within a minute.`;
  });
}

export async function removeKeyAction(f: FormData) {
  await run("/admin/keys", async ({ db, actor }) => {
    const p = provider(f);
    await ops.removeKey(db, actor, p);
    return `${PROVIDER_INFO[p].label} key removed — falling back to ${PROVIDER_INFO[p].envVar} if set.`;
  });
}

export async function testKeyAction(f: FormData) {
  await run("/admin/keys", async ({ db, actor }) => {
    const p = provider(f);
    const r = await ops.testKey(db, actor, p);
    if (!r.ok) throw new Error(`${PROVIDER_INFO[p].label} (${r.source}) failed in ${r.latencyMs} ms: ${r.error ?? "error"}`);
    return `${PROVIDER_INFO[p].label} (${r.source}) OK in ${r.latencyMs} ms.`;
  });
}

// MARK: - Config

async function freshConfig(ctx: Ctx): Promise<ProductConfig> {
  return normalizeConfig(await ctx.db.adminGetConfig(CONFIG_KEY));
}

export async function toggleFeatureAction(f: FormData) {
  await run("/admin/config", async (ctx) => {
    const sw = str(f, "feature");
    if (!(FEATURE_SWITCHES as readonly string[]).includes(sw)) throw new ops.AdminInputError("Unknown feature.");
    const before = await freshConfig(ctx);
    const on = str(f, "on") === "1";
    await ops.updateConfig(ctx.db, ctx.actor, before, { features: { ...before.features, [sw]: on } });
    return `${sw} switched ${on ? "ON" : "OFF"}. Other instances follow within 30 s.`;
  });
}

export async function saveNoticeAction(f: FormData) {
  await run("/admin/config", async (ctx) => {
    const before = await freshConfig(ctx);
    const clear = str(f, "clear") === "1";
    const notice = clear ? null : makeNotice(str(f, "message"), str(f, "level"), str(f, "url"));
    await ops.updateConfig(ctx.db, ctx.actor, before, { notice });
    return notice ? "Notice published." : "Notice cleared.";
  });
}

export async function saveVersionsAction(f: FormData) {
  await run("/admin/config", async (ctx) => {
    const before = await freshConfig(ctx);
    const want = { minAppVersion: str(f, "minAppVersion") || null, latestVersion: str(f, "latestVersion") || null, downloadURL: str(f, "downloadURL") || null };
    const saved = await ops.updateConfig(ctx.db, ctx.actor, before, want);
    const dropped = (Object.keys(want) as (keyof typeof want)[]).filter((k) => want[k] && !saved[k]);
    if (dropped.length) throw new ops.AdminInputError(`Not saved (invalid): ${dropped.join(", ")}. Versions look like 1.4.2; URLs need http(s).`);
    return "Versions saved.";
  });
}

function parseCap(raw: string): number | null | undefined {
  const v = raw.trim().toLowerCase();
  if (!v) return undefined;
  if (v === "none" || v === "unlimited" || v === "∞") return null;
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0) throw new ops.AdminInputError(`Bad quota "${raw}" — a number, "unlimited", or blank for the default.`);
  return Math.floor(n);
}

export async function saveQuotasAction(f: FormData) {
  await run("/admin/config", async (ctx) => {
    const before = await freshConfig(ctx);
    const quotas: ProductConfig["quotas"] = {};
    for (const tier of TIERS) {
      const o: QuotaOverride = {};
      for (const k of ["answersPerDay", "tasksPerDay", "tasksPerMonth"] as const) {
        const c = parseCap(str(f, `${tier}.${k}`));
        if (c !== undefined) o[k] = c;
      }
      if (Object.keys(o).length) quotas[tier] = o;
    }
    await ops.updateConfig(ctx.db, ctx.actor, before, { quotas });
    return "Quotas saved.";
  });
}

export async function saveModelsAction(f: FormData) {
  await run("/admin/config", async (ctx) => {
    const before = await freshConfig(ctx);
    const models = { ...before.models };
    for (const m of MODEL_FEATURES) models[m] = str(f, m) || null;
    const saved = await ops.updateConfig(ctx.db, ctx.actor, before, { models });
    const dropped = MODEL_FEATURES.filter((m) => models[m] && !saved.models[m]);
    if (dropped.length) throw new ops.AdminInputError(`Not saved (invalid model id): ${dropped.join(", ")}.`);
    return "Models saved.";
  });
}

export async function addAdminAction(f: FormData) {
  await run("/admin/config", async ({ db, actor }) => {
    await ops.addAdmin(db, actor, str(f, "email"));
    return `${str(f, "email")} is now an admin.`;
  });
}

export async function removeAdminAction(f: FormData) {
  await run("/admin/config", async ({ db, actor }) => {
    await ops.removeAdmin(db, actor, str(f, "email"));
    return `${str(f, "email")} removed from the admins table.`;
  });
}

// MARK: - Waitlist

const waitlistBack = (f: FormData) => `/admin/waitlist${str(f, "q") ? `?q=${encodeURIComponent(str(f, "q"))}` : ""}`;

export async function inviteAction(f: FormData) {
  await run(waitlistBack(f), async ({ db, actor }) => {
    // The invite email's link lands on the download page when one is configured.
    const cfg = normalizeConfig(await db.adminGetConfig(CONFIG_KEY));
    await ops.inviteFromWaitlist(db, actor, str(f, "email"), cfg.downloadURL ?? `${env.baseUrl}/auth/start?redirect=navi`);
    return db.driver === "memory" ? `Marked ${str(f, "email")} invited (memory driver: no email sent).` : `Invite sent to ${str(f, "email")}.`;
  });
}

export async function markInvitedAction(f: FormData) {
  await run(waitlistBack(f), async ({ db, actor }) => {
    await ops.markInvited(db, actor, str(f, "email"));
    return `Marked ${str(f, "email")} invited.`;
  });
}
