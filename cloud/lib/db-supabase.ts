/**
 * Postgres driver over the Supabase service-role client. Schema in
 * supabase/migrations/0001_init.sql. RLS is on for every table; the service
 * role bypasses it, which is why this module is the only thing that writes.
 */

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { AdminDb, AuthCodeRecord, Db, EntitlementGrant, Profile, ProfilePatch, QuotaReset, SessionTokens, UsageRecord, UsageUnit, UsageWindow, VendorKeyRow } from "./db";
import { pseudonym } from "./db";
import { env } from "./env";
import type { Feature } from "./plans";
import { trialEnd } from "./plans";

interface ProfileRow {
  user_id: string;
  email: string;
  tier: Profile["tier"];
  trial_ends_at: string | null;
  stripe_customer_id: string | null;
  stripe_subscription_id: string | null;
  subscription_status: string | null;
  created_at: string;
  // 0002_admin.sql (absent until applied)
  tier_override?: Profile["tier"] | null;
  disabled_at?: string | null;
  disabled_reason?: string | null;
  quota_reset?: QuotaReset | null;
}

function fromRow(r: ProfileRow): Profile {
  return {
    userId: r.user_id,
    email: r.email,
    tier: r.tier,
    trialEndsAt: r.trial_ends_at,
    stripeCustomerId: r.stripe_customer_id,
    stripeSubscriptionId: r.stripe_subscription_id,
    subscriptionStatus: r.subscription_status,
    createdAt: r.created_at,
    tierOverride: r.tier_override ?? null,
    disabledAt: r.disabled_at ?? null,
    disabledReason: r.disabled_reason ?? null,
    quotaReset: r.quota_reset ?? null,
  };
}

function toPatch(p: ProfilePatch): Partial<ProfileRow> {
  const out: Partial<ProfileRow> = {};
  if (p.tier !== undefined) out.tier = p.tier;
  if (p.trialEndsAt !== undefined) out.trial_ends_at = p.trialEndsAt;
  if (p.stripeCustomerId !== undefined) out.stripe_customer_id = p.stripeCustomerId;
  if (p.stripeSubscriptionId !== undefined) out.stripe_subscription_id = p.stripeSubscriptionId;
  if (p.subscriptionStatus !== undefined) out.subscription_status = p.subscriptionStatus;
  if (p.tierOverride !== undefined) out.tier_override = p.tierOverride;
  if (p.disabledAt !== undefined) out.disabled_at = p.disabledAt;
  if (p.disabledReason !== undefined) out.disabled_reason = p.disabledReason;
  if (p.quotaReset !== undefined) out.quota_reset = p.quotaReset;
  return out;
}

/** Service-role client (no session persistence; server only). */
export function serviceClient(): SupabaseClient {
  const url = env.supabaseUrl;
  const key = env.supabaseServiceKey;
  if (!url || !key) throw new Error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required for the supabase db driver");
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

export function createSupabaseDb(client: SupabaseClient = serviceClient()): Db {
  const sb = client;

  function must<T>(res: { data: T; error: { message: string } | null }, what: string): T {
    if (res.error) throw new Error(`supabase ${what}: ${res.error.message}`);
    return res.data;
  }

  return {
    driver: "supabase",

    async ensureProfile(userId, email, now) {
      const existing = await this.getProfile(userId);
      if (existing) return existing;
      // Race-safe: the auth trigger may have inserted the row a moment ago.
      must(
        await sb.from("profiles").upsert(
          { user_id: userId, email, tier: "free", trial_ends_at: trialEnd(now).toISOString() },
          { onConflict: "user_id", ignoreDuplicates: true },
        ),
        "profiles.upsert",
      );
      const p = await this.getProfile(userId);
      if (!p) throw new Error("supabase: profile missing after upsert");
      return p;
    },
    async getProfile(userId) {
      const data = must(await sb.from("profiles").select("*").eq("user_id", userId).maybeSingle<ProfileRow>(), "profiles.select");
      return data ? fromRow(data) : null;
    },
    async getProfileByStripeCustomer(customerId) {
      const data = must(
        await sb.from("profiles").select("*").eq("stripe_customer_id", customerId).maybeSingle<ProfileRow>(),
        "profiles.byCustomer",
      );
      return data ? fromRow(data) : null;
    },
    async updateProfile(userId, patch) {
      const data = must(
        await sb.from("profiles").update(toPatch(patch)).eq("user_id", userId).select("*").single<ProfileRow>(),
        "profiles.update",
      );
      if (!data) throw new Error(`supabase profiles.update: no profile ${userId}`);
      return fromRow(data);
    },

    async listEntitlements(userId) {
      const rows = must(
        await sb.from("entitlements").select("key, granted_by, expires_at").eq("user_id", userId),
        "entitlements.select",
      ) as { key: string; granted_by: string; expires_at: string | null }[];
      return rows.map<EntitlementGrant>((r) => ({ key: r.key, grantedBy: r.granted_by, expiresAt: r.expires_at }));
    },
    async grantEntitlement(userId, key, grantedBy, expiresAt) {
      must(
        await sb.from("entitlements").upsert({ user_id: userId, key, granted_by: grantedBy, expires_at: expiresAt }, { onConflict: "user_id,key" }),
        "entitlements.upsert",
      );
    },

    async recordUsage(unit: UsageUnit) {
      const data = must(
        await sb
          .from("usage")
          .upsert(
            { user_id: unit.userId, feature: unit.feature, run_id: unit.runId, day: unit.day, month: unit.month, cost_usd: 0 },
            { onConflict: "user_id,feature,run_id", ignoreDuplicates: true },
          )
          .select("run_id"),
        "usage.upsert",
      ) as { run_id: string }[] | null;
      return Boolean(data && data.length > 0);
    },
    async hasUsage(userId, feature, runId) {
      const data = must(
        await sb.from("usage").select("run_id").eq("user_id", userId).eq("feature", feature).eq("run_id", runId).maybeSingle(),
        "usage.has",
      );
      return data != null;
    },
    async addUsageCost(userId, feature, runId, costUsd) {
      must(await sb.rpc("add_usage_cost", { p_user_id: userId, p_feature: feature, p_run_id: runId, p_cost: costUsd }), "usage.addCost");
    },
    async countUsage(userId, features: readonly Feature[], window: UsageWindow) {
      let q = sb.from("usage").select("run_id", { count: "exact", head: true }).eq("user_id", userId).in("feature", [...features]);
      q = "day" in window ? q.eq("day", window.day) : q.eq("month", window.month);
      const res = await q;
      if (res.error) throw new Error(`supabase usage.count: ${res.error.message}`);
      return res.count ?? 0;
    },

    async createAuthCode(record: AuthCodeRecord) {
      must(
        await sb.from("auth_codes").insert({
          code: record.code,
          access_token: record.tokens.accessToken,
          refresh_token: record.tokens.refreshToken,
          token_expires_at: record.tokens.expiresAt,
          expires_at: record.expiresAt,
        }),
        "auth_codes.insert",
      );
    },
    async consumeAuthCode(code, now) {
      // DELETE … RETURNING makes the code single-use even under concurrent exchanges.
      const rows = must(
        await sb.from("auth_codes").delete().eq("code", code).select("access_token, refresh_token, token_expires_at, expires_at"),
        "auth_codes.consume",
      ) as { access_token: string; refresh_token: string; token_expires_at: string; expires_at: string }[] | null;
      const row = rows?.[0];
      if (!row) return null;
      if (new Date(row.expires_at).getTime() <= now.getTime()) return null;
      const tokens: SessionTokens = { accessToken: row.access_token, refreshToken: row.refresh_token, expiresAt: row.token_expires_at };
      return tokens;
    },

    async addToWaitlist(email, source, note) {
      const data = must(
        await sb
          .from("waitlist")
          .upsert({ email: email.toLowerCase(), source, note }, { onConflict: "email", ignoreDuplicates: true })
          .select("email"),
        "waitlist.upsert",
      ) as { email: string }[] | null;
      return { created: Boolean(data && data.length > 0) };
    },

    // MARK: account
    async createUserAuthCode(userId, record) {
      must(
        await sb.from("auth_codes").insert({
          code: record.code,
          user_id: userId,
          access_token: record.tokens.accessToken,
          refresh_token: record.tokens.refreshToken,
          token_expires_at: record.tokens.expiresAt,
          expires_at: record.expiresAt,
        }),
        "auth_codes.insert",
      );
    },
    async exportUserData(userId, email) {
      const profile = await this.getProfile(userId);
      const entitlementRows = must(
        await sb.from("entitlements").select("key, granted_by, expires_at, created_at").eq("user_id", userId),
        "entitlements.export",
      ) as { key: string; granted_by: string; expires_at: string | null; created_at: string }[];
      // PostgREST caps a response at 1000 rows; a heavy user has more usage than that.
      const usage: UsageRecord[] = [];
      const PAGE = 1000;
      for (let from = 0; ; from += PAGE) {
        const rows = must(
          await sb
            .from("usage")
            .select("feature, run_id, day, month, cost_usd, created_at")
            .eq("user_id", userId)
            .order("created_at", { ascending: true })
            .order("run_id", { ascending: true })
            .range(from, from + PAGE - 1),
          "usage.export",
        ) as { feature: UsageRecord["feature"]; run_id: string; day: string; month: string; cost_usd: number | string; created_at: string }[];
        for (const r of rows) {
          usage.push({ feature: r.feature, runId: r.run_id, day: r.day, month: r.month, costUsd: Number(r.cost_usd), createdAt: r.created_at });
        }
        if (rows.length < PAGE) break;
      }
      const w = email
        ? (must(
            await sb.from("waitlist").select("email, source, note, created_at").eq("email", email.toLowerCase()).maybeSingle(),
            "waitlist.export",
          ) as { email: string; source: string | null; note: string | null; created_at: string } | null)
        : null;
      return {
        profile,
        entitlements: entitlementRows.map((r) => ({ key: r.key, grantedBy: r.granted_by, expiresAt: r.expires_at })),
        usage,
        waitlist: w ? { email: w.email, source: w.source, note: w.note, createdAt: w.created_at } : null,
      };
    },
    async deleteUserData(userId, email) {
      const del = async (table: string, column: string, value: string) => {
        const res = await sb.from(table).delete({ count: "exact" }).eq(column, value);
        if (res.error) throw new Error(`supabase ${table}.delete: ${res.error.message}`);
        return res.count ?? 0;
      };
      // Children first; profiles last so a half-finished delete can be retried by the same user.
      const usage = await del("usage", "user_id", userId);
      const entitlements = await del("entitlements", "user_id", userId);
      const authCodes = await del("auth_codes", "user_id", userId);
      const waitlist = email ? await del("waitlist", "email", email.toLowerCase()) : 0;
      // Admin-side traces (0002_admin.sql): audit entries keep the action but lose the email;
      // a database-granted admin role for this address goes. Tolerated before 0002 is applied.
      const missingTable = (m: string) => /does not exist|could not find the table|schema cache/i.test(m);
      let auditPseudonymized = 0;
      let adminRole = 0;
      if (email) {
        const au = await sb.from("admin_audit").update({ target: pseudonym(userId) }, { count: "exact" }).eq("target", email.toLowerCase());
        if (au.error && !missingTable(au.error.message)) throw new Error(`supabase admin_audit.pseudonymize: ${au.error.message}`);
        auditPseudonymized = au.count ?? 0;
        const ad = await sb.from("admins").delete({ count: "exact" }).eq("email", email.toLowerCase());
        if (ad.error && !missingTable(ad.error.message)) throw new Error(`supabase admins.delete: ${ad.error.message}`);
        adminRole = ad.count ?? 0;
      }
      const profile = await del("profiles", "user_id", userId);
      return { profile, entitlements, usage, authCodes, waitlist, auditPseudonymized, adminRole };
    },
    async purgeExpired() {
      const data = must(await sb.rpc("navi_purge"), "navi_purge") as { auth_codes?: number; rate_limits?: number } | null;
      return { authCodes: Number(data?.auth_codes ?? 0), rateLimits: Number(data?.rate_limits ?? 0) };
    },

    ...createSupabaseAdmin(sb, must),
  };
}

// MARK: admin
// The admin console's storage (supabase/migrations/0002_admin.sql). Aggregations that
// would otherwise pull every usage row run as SQL functions (admin_usage_*).

type Must = <T>(res: { data: T; error: { message: string } | null }, what: string) => T;

interface VendorKeyDbRow {
  provider: string;
  ciphertext: string | null;
  last4: string | null;
  rotated_at: string | null;
  rotated_by: string | null;
  last_used_at: string | null;
  last_test_at: string | null;
  last_test_ok: boolean | null;
  last_test_latency_ms: number | null;
  last_test_error: string | null;
}

function vendorKeyFromRow(r: VendorKeyDbRow): VendorKeyRow {
  return {
    provider: r.provider,
    ciphertext: r.ciphertext,
    last4: r.last4,
    rotatedAt: r.rotated_at,
    rotatedBy: r.rotated_by,
    lastUsedAt: r.last_used_at,
    lastTestAt: r.last_test_at,
    lastTestOk: r.last_test_ok,
    lastTestLatencyMs: r.last_test_latency_ms,
    lastTestError: r.last_test_error,
  };
}

/** `ilike` pattern with the admin's text taken literally. */
function likePattern(q: string): string {
  return `%${q.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
}

function createSupabaseAdmin(sb: SupabaseClient, must: Must): AdminDb {
  return {
    async adminListProfiles(q) {
      let query = sb.from("profiles").select("*", { count: "exact" }).order("created_at", { ascending: false });
      const needle = q.query?.trim();
      if (needle) {
        query = /^[0-9a-f-]{36}$/i.test(needle) ? query.eq("user_id", needle) : query.ilike("email", likePattern(needle));
      }
      const res = await query.range(q.offset, q.offset + q.limit - 1);
      if (res.error) throw new Error(`supabase admin.profiles: ${res.error.message}`);
      return { rows: ((res.data ?? []) as ProfileRow[]).map(fromRow), total: res.count ?? 0 };
    },
    async adminAllProfiles() {
      const out: Profile[] = [];
      const PAGE = 1000;
      for (let from = 0; ; from += PAGE) {
        const rows = (must(
          await sb.from("profiles").select("*").order("created_at", { ascending: true }).range(from, from + PAGE - 1),
          "admin.profiles.all",
        ) ?? []) as ProfileRow[];
        out.push(...rows.map(fromRow));
        if (rows.length < PAGE) break;
      }
      return out;
    },
    async adminRevokeEntitlement(userId, key) {
      must(await sb.from("entitlements").delete().eq("user_id", userId).eq("key", key), "admin.entitlements.delete");
    },
    async adminUsageByFeature(userId) {
      const rows = must(await sb.rpc("admin_usage_by_feature", { p_user_id: userId }), "admin.usage_by_feature") as
        { feature: Feature; runs: number | string; cost_usd: number | string; last_day: string | null }[] | null;
      return (rows ?? []).map((r) => ({ feature: r.feature, runs: Number(r.runs), costUsd: Number(r.cost_usd), lastDay: r.last_day }));
    },
    async adminUsageDaily(sinceDay) {
      const rows = must(await sb.rpc("admin_usage_daily", { p_since: sinceDay }), "admin.usage_daily") as
        { day: string; active_users: number | string; runs: number | string; cost_usd: number | string }[] | null;
      return (rows ?? []).map((r) => ({ day: r.day, activeUsers: Number(r.active_users), runs: Number(r.runs), costUsd: Number(r.cost_usd) }));
    },
    async adminActiveUsers(sinceDay) {
      return Number(must(await sb.rpc("admin_active_users", { p_since: sinceDay }), "admin.active_users") ?? 0);
    },
    async adminSignOutUser(userId) {
      must(await sb.rpc("admin_sign_out_user", { p_user_id: userId }), "admin.sign_out_user");
    },
    async adminDeleteUser(userId) {
      const res = await sb.auth.admin.deleteUser(userId);
      if (res.error) throw new Error(`supabase admin.deleteUser: ${res.error.message}`);
    },

    async adminListWaitlist(q) {
      let query = sb.from("waitlist").select("*", { count: "exact" }).order("created_at", { ascending: false });
      const needle = q.query?.trim();
      if (needle) query = query.ilike("email", likePattern(needle));
      const res = await query.range(q.offset, q.offset + q.limit - 1);
      if (res.error) throw new Error(`supabase admin.waitlist: ${res.error.message}`);
      const rows = (res.data ?? []) as { email: string; source: string | null; note: string | null; created_at: string; invited_at?: string | null }[];
      return {
        rows: rows.map((r) => ({ email: r.email, source: r.source, note: r.note, createdAt: r.created_at, invitedAt: r.invited_at ?? null })),
        total: res.count ?? 0,
      };
    },
    async adminCountWaitlist() {
      const res = await sb.from("waitlist").select("email", { count: "exact", head: true });
      if (res.error) throw new Error(`supabase admin.waitlist.count: ${res.error.message}`);
      return res.count ?? 0;
    },
    async adminInviteUser(email, redirectTo) {
      const res = await sb.auth.admin.inviteUserByEmail(email, { redirectTo });
      if (res.error) throw new Error(res.error.message);
    },
    async adminMarkInvited(email, at) {
      must(await sb.from("waitlist").update({ invited_at: at }).eq("email", email.toLowerCase()), "admin.waitlist.invited");
    },

    async adminIsListedAdmin(email) {
      const data = must(await sb.from("admins").select("email").eq("email", email.toLowerCase()).maybeSingle(), "admin.admins.get");
      return data != null;
    },
    async adminListAdmins() {
      const rows = must(await sb.from("admins").select("email, added_by, created_at").order("email"), "admin.admins.list") as
        { email: string; added_by: string; created_at: string }[] | null;
      return (rows ?? []).map((r) => ({ email: r.email, addedBy: r.added_by, createdAt: r.created_at }));
    },
    async adminAddAdmin(email, addedBy) {
      must(
        await sb.from("admins").upsert({ email: email.toLowerCase(), added_by: addedBy }, { onConflict: "email", ignoreDuplicates: true }),
        "admin.admins.add",
      );
    },
    async adminRemoveAdmin(email) {
      must(await sb.from("admins").delete().eq("email", email.toLowerCase()), "admin.admins.remove");
    },

    async adminGetVendorKeys() {
      const rows = must(await sb.from("vendor_keys").select("*"), "admin.vendor_keys.list") as VendorKeyDbRow[] | null;
      return (rows ?? []).map(vendorKeyFromRow);
    },
    async adminGetVendorKey(provider) {
      const row = must(await sb.from("vendor_keys").select("*").eq("provider", provider).maybeSingle<VendorKeyDbRow>(), "admin.vendor_keys.get");
      return row ? vendorKeyFromRow(row) : null;
    },
    async adminSetVendorKey(provider, ciphertext, last4, by, at) {
      must(
        await sb.from("vendor_keys").upsert(
          {
            provider, ciphertext, last4, rotated_at: at, rotated_by: by,
            last_test_at: null, last_test_ok: null, last_test_latency_ms: null, last_test_error: null,
          },
          { onConflict: "provider" },
        ),
        "admin.vendor_keys.set",
      );
    },
    async adminUpdateVendorKeyMeta(provider, meta) {
      const row: Partial<VendorKeyDbRow> & { provider: string } = { provider };
      if (meta.lastUsedAt !== undefined) row.last_used_at = meta.lastUsedAt;
      if (meta.lastTestAt !== undefined) row.last_test_at = meta.lastTestAt;
      if (meta.lastTestOk !== undefined) row.last_test_ok = meta.lastTestOk;
      if (meta.lastTestLatencyMs !== undefined) row.last_test_latency_ms = meta.lastTestLatencyMs;
      if (meta.lastTestError !== undefined) row.last_test_error = meta.lastTestError;
      must(await sb.from("vendor_keys").upsert(row, { onConflict: "provider" }), "admin.vendor_keys.meta");
    },

    async adminGetConfig(key) {
      const row = must(await sb.from("app_config").select("value").eq("key", key).maybeSingle<{ value: unknown }>(), "admin.app_config.get");
      return row ? row.value : null;
    },
    async adminSetConfig(key, value, by) {
      must(
        await sb.from("app_config").upsert({ key, value, updated_by: by, updated_at: new Date().toISOString() }, { onConflict: "key" }),
        "admin.app_config.set",
      );
    },

    async adminWriteAudit(entry) {
      must(
        await sb.from("admin_audit").insert({ actor: entry.actor, action: entry.action, target: entry.target, details: entry.details, at: entry.at }),
        "admin.audit.insert",
      );
    },
    async adminListAudit(q) {
      let query = sb.from("admin_audit").select("*", { count: "exact" }).order("at", { ascending: false });
      const needle = q.query?.trim().replace(/[,()*%_\\]/g, " ").trim();
      if (needle) query = query.or(`actor.ilike.*${needle}*,action.ilike.*${needle}*,target.ilike.*${needle}*`);
      const res = await query.range(q.offset, q.offset + q.limit - 1);
      if (res.error) throw new Error(`supabase admin.audit: ${res.error.message}`);
      const rows = (res.data ?? []) as { id: number | string; actor: string; action: string; target: string | null; details: Record<string, unknown> | null; at: string }[];
      return {
        rows: rows.map((r) => ({ id: String(r.id), actor: r.actor, action: r.action, target: r.target, details: r.details ?? {}, at: r.at })),
        total: res.count ?? 0,
      };
    },
  };
}
