import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { verifyAccessToken, type AuthUser } from "@/lib/auth";
import { stripeConfigured } from "@/lib/billing";
import { getDb } from "@/lib/db";
import { env } from "@/lib/env";
import { meBody } from "@/lib/metering";
import type { Tier } from "@/lib/plans";
import { getSessionProvider } from "@/lib/sessions";
import { startPath } from "@/lib/signin";
import { decodeSession, secondsUntilExpiry, SESSION_COOKIE } from "@/lib/web-session";
import { Foot, Shell } from "../auth/ui";
import { AccountActions, DangerZone, DeviceActions, ExportButton, SignOutButton } from "./account-client";

export const dynamic = "force-dynamic";

type Search = Record<string, string | string[] | undefined>;

const PLAN_NAMES: Record<Tier, string> = { free: "Free", pro: "Pro", pro_recall: "Pro + Recall" };

function ago(iso: string, now: Date): string {
  const s = Math.max(0, Math.round((now.getTime() - new Date(iso).getTime()) / 1000));
  if (s < 90) return "just now";
  const m = Math.round(s / 60);
  if (m < 90) return `${m} minutes ago`;
  const h = Math.round(m / 60);
  if (h < 36) return `${h} hours ago`;
  const d = Math.round(h / 24);
  return d === 1 ? "yesterday" : `${d} days ago`;
}

function until(iso: string, now: Date): string {
  const s = Math.max(0, Math.round((new Date(iso).getTime() - now.getTime()) / 1000));
  const h = Math.round(s / 3600);
  if (h < 1) return "in under an hour";
  if (h < 36) return `in ${h} hour${h === 1 ? "" : "s"}`;
  const d = Math.round(h / 24);
  return `in ${d} day${d === 1 ? "" : "s"}`;
}

function Meter({ label, used, limit }: { label: string; used: number; limit?: number }) {
  const pct = limit ? Math.min(100, Math.round((used / limit) * 100)) : 0;
  return (
    <div className="nv-meter">
      <div className="nv-meter-top">
        <span>{label}</span>
        <span className="nv-tnum nv-muted">
          {used}
          {limit != null ? ` of ${limit}` : ""}
        </span>
      </div>
      {limit != null && (
        <div className="nv-meter-bar" role="progressbar" aria-label={label} aria-valuemin={0} aria-valuemax={limit} aria-valuenow={used}>
          <div className={`nv-meter-fill${pct >= 100 ? " nv-full" : ""}`} style={{ width: `${pct}%` }} />
        </div>
      )}
    </div>
  );
}

/** Resolves the cookie session or bounces: no cookie → sign in; stale token → /account/refresh. */
async function currentUser(): Promise<AuthUser> {
  const jar = await cookies();
  const session = decodeSession(jar.get(SESSION_COOKIE)?.value);
  if (!session) redirect(startPath("account"));
  const left = secondsUntilExpiry(session.accessToken);
  if (left === null || left < 120) redirect("/account/refresh?next=/account");
  try {
    return await verifyAccessToken(session.accessToken);
  } catch {
    redirect("/account/refresh?next=/account");
  }
}

export default async function AccountPage({ searchParams }: { searchParams: Promise<Search> }) {
  const params = await searchParams;
  const user = await currentUser();
  const sessions = getSessionProvider();
  // A deleted account's token can outlive it by up to an hour; the refresh will fail and sign out.
  if (!(await sessions.userExists(user.id))) redirect("/account/refresh?next=/account");

  const now = new Date();
  const db = await getDb();
  const me = (await meBody(db, user, now)) as {
    user: { id: string; email: string };
    tier: Tier;
    trialEndsAt?: string;
    quotas: { answersPerDay?: number; tasksPerDay?: number; tasksPerMonth?: number };
    usage: { answersToday: number; tasksToday: number; tasksThisMonth: number; resetsAt: string };
    entitlements: Record<string, boolean>;
  };
  const profile = await db.getProfile(user.id);
  const devices = await sessions.listSessions(user.id);

  const billingOn = stripeConfigured();
  const prices = env.stripePrices;
  const paidTier: Tier = profile?.tier ?? "free";
  const hasSubscription = Boolean(profile?.stripeSubscriptionId && profile.subscriptionStatus !== "canceled");
  const billingParam = typeof params.billing === "string" ? params.billing : undefined;

  return (
    <Shell right={<SignOutButton />}>
      <main className="nv-wide">
        <h1 className="nv-h1">Your account</h1>
        <p className="nv-lede">{me.user.email}</p>

        {billingParam === "success" && (
          <div className="nv-banner nv-banner-ok" role="status">
            <strong>You’re all set</strong>
            Your new plan is active. Navi on your Mac picks it up within a minute.
          </div>
        )}
        {billingParam === "cancel" && (
          <div className="nv-banner nv-banner-info" role="status">
            Checkout was cancelled — nothing changed.
          </div>
        )}
        {billingParam === "updated" && (
          <div className="nv-banner nv-banner-info" role="status">
            Billing updated.
          </div>
        )}
        {profile?.subscriptionStatus === "past_due" && (
          <div className="nv-banner nv-banner-warn" role="alert">
            <strong>Your last payment didn’t go through</strong>
            Update your card in Manage billing to keep {PLAN_NAMES[paidTier]}.
          </div>
        )}

        <section className="nv-card" aria-labelledby="plan-h">
          <div className="nv-card-head">
            <h2 className="nv-h2" id="plan-h">
              Plan
            </h2>
            <span className="nv-pill nv-pill-accent">{me.trialEndsAt ? "Pro trial" : PLAN_NAMES[me.tier]}</span>
          </div>
          {me.trialEndsAt ? (
            <p className="nv-muted" style={{ margin: 0 }}>
              Your free Pro trial ends {until(me.trialEndsAt, now)}. After that you’re on Free unless you pick a plan.
            </p>
          ) : (
            <p className="nv-muted" style={{ margin: 0 }}>
              {me.tier === "free"
                ? "Apps, files and system commands are free forever. Upgrade for more answers, tasks and voice."
                : me.tier === "pro"
                  ? "Unlimited answers (fair use), 300 tasks a month and voice control."
                  : "Everything in Pro, plus Recall — a private memory of your screen that stays on your Mac."}
            </p>
          )}

          <Meter label="Answers today" used={me.usage.answersToday} limit={me.quotas.answersPerDay} />
          {me.quotas.tasksPerDay != null ? (
            <Meter label="Tasks today" used={me.usage.tasksToday} limit={me.quotas.tasksPerDay} />
          ) : (
            <Meter label="Tasks this month" used={me.usage.tasksThisMonth} limit={me.quotas.tasksPerMonth} />
          )}
          <p className="nv-dim" style={{ margin: "10px 0 0" }}>
            Limits reset {until(me.usage.resetsAt, now)}.
          </p>

          <AccountActions
            billingEnabled={billingOn}
            hasCustomer={Boolean(profile?.stripeCustomerId)}
            hasSubscription={hasSubscription}
            paidTier={paidTier}
            available={{
              pro: { month: Boolean(prices.pro_month), year: Boolean(prices.pro_year) },
              pro_recall: { month: Boolean(prices.pro_recall_month), year: Boolean(prices.pro_recall_year) },
            }}
          />
        </section>

        <section className="nv-card" aria-labelledby="dl-h">
          <div className="nv-card-head">
            <h2 className="nv-h2" id="dl-h">
              Download Navi
            </h2>
            <span className="nv-dim">macOS 26 · Apple silicon</span>
          </div>
          {env.downloadUrl ? (
            <div className="nv-row">
              <a className="nv-btn nv-btn-primary" href={env.downloadUrl}>
                Download for Mac
              </a>
              <span className="nv-dim">Open the disk image and drag Navi to Applications, then sign in from the menu bar.</span>
            </div>
          ) : (
            <p className="nv-muted" style={{ margin: 0 }}>
              The download opens soon — we’ll email you the moment it does.
            </p>
          )}
        </section>

        <section className="nv-card" aria-labelledby="dev-h">
          <div className="nv-card-head">
            <h2 className="nv-h2" id="dev-h">
              Signed-in devices
            </h2>
            <span className="nv-dim">{devices.length === 1 ? "1 session" : `${devices.length} sessions`}</span>
          </div>
          {devices.length > 0 ? (
            <ul className="nv-list">
              {devices.map((d) => (
                <li key={d.id}>
                  <span>
                    {d.id === user.sessionId ? "This browser" : "Mac or browser"}
                    <span className="nv-dim"> · signed in {ago(d.createdAt, now)}</span>
                  </span>
                  <span className="nv-dim">active {ago(d.lastActiveAt, now)}</span>
                </li>
              ))}
            </ul>
          ) : (
            <p className="nv-muted" style={{ margin: 0 }}>
              No other sessions.
            </p>
          )}
          <DeviceActions />
        </section>

        <section className="nv-card" aria-labelledby="data-h">
          <div className="nv-card-head">
            <h2 className="nv-h2" id="data-h">
              Your data
            </h2>
          </div>
          <p className="nv-muted" style={{ marginTop: 0 }}>
            Navi’s servers keep your email, your plan, and a count of what you used each day — never what you asked, what Navi
            answered, or anything on your screen. Recall’s memory stays on your Mac.
          </p>
          <div className="nv-row">
            <ExportButton />
          </div>
        </section>

        <DangerZone email={me.user.email} hasSubscription={hasSubscription} />
        <Foot />
      </main>
    </Shell>
  );
}
