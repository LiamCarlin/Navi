/**
 * Postgres driver over the Supabase service-role client. Schema in
 * supabase/migrations/0001_init.sql. RLS is on for every table; the service
 * role bypasses it, which is why this module is the only thing that writes.
 */

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { AuthCodeRecord, Db, EntitlementGrant, Profile, ProfilePatch, SessionTokens, UsageRecord, UsageUnit, UsageWindow } from "./db";
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
  };
}

function toPatch(p: ProfilePatch): Partial<ProfileRow> {
  const out: Partial<ProfileRow> = {};
  if (p.tier !== undefined) out.tier = p.tier;
  if (p.trialEndsAt !== undefined) out.trial_ends_at = p.trialEndsAt;
  if (p.stripeCustomerId !== undefined) out.stripe_customer_id = p.stripeCustomerId;
  if (p.stripeSubscriptionId !== undefined) out.stripe_subscription_id = p.stripeSubscriptionId;
  if (p.subscriptionStatus !== undefined) out.subscription_status = p.subscriptionStatus;
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
      const profile = await del("profiles", "user_id", userId);
      return { profile, entitlements, usage, authCodes, waitlist };
    },
    async purgeExpired() {
      const data = must(await sb.rpc("navi_purge"), "navi_purge") as { auth_codes?: number; rate_limits?: number } | null;
      return { authCodes: Number(data?.auth_codes ?? 0), rateLimits: Number(data?.rate_limits ?? 0) };
    },
  };
}
