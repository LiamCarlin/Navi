"use client";

import { useState } from "react";

type Tier = "free" | "pro" | "pro_recall";
type Interval = "month" | "year";

/**
 * fetch for /account actions: same-origin cookie, and one silent retry after refreshing the
 * session when the access token has expired (it lives an hour; the page may be open longer).
 */
async function accountFetch(path: string, init: RequestInit = {}): Promise<Response> {
  const go = () => fetch(path, { ...init, credentials: "same-origin", headers: { "content-type": "application/json", ...(init.headers ?? {}) } });
  let res = await go();
  if (res.status === 401) {
    const body = (await res.clone().json().catch(() => ({}))) as { error?: string };
    if (body.error === "session_expired") {
      const r = await fetch("/account/refresh", { method: "POST", credentials: "same-origin" });
      if (r.ok) res = await go();
    }
    if (res.status === 401) {
      window.location.assign("/auth/start?redirect=account&error=session_expired");
    }
  }
  return res;
}

async function errorMessage(res: Response): Promise<string> {
  const body = (await res.json().catch(() => ({}))) as { message?: string };
  return body.message ?? "Something went wrong. Try again.";
}

const PRICES: Record<"pro" | "pro_recall", Record<Interval, string>> = {
  pro: { month: "$20 / month", year: "$192 / year" },
  pro_recall: { month: "$30 / month", year: "$288 / year" },
};

export function AccountActions({
  billingEnabled,
  hasCustomer,
  hasSubscription,
  paidTier,
  available,
}: {
  billingEnabled: boolean;
  hasCustomer: boolean;
  hasSubscription: boolean;
  paidTier: Tier;
  available: Record<"pro" | "pro_recall", Record<Interval, boolean>>;
}) {
  const [interval, setInterval] = useState<Interval>("month");
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function billing(body: Record<string, unknown>, key: string) {
    setBusy(key);
    setError(null);
    const res = await accountFetch("/account/billing", { method: "POST", body: JSON.stringify(body) });
    if (res.ok) {
      const { url } = (await res.json()) as { url: string };
      window.location.assign(url);
      return;
    }
    setBusy(null);
    setError(await errorMessage(res));
  }

  if (!billingEnabled) {
    return (
      <p className="nv-dim" style={{ margin: "16px 0 0" }}>
        Paid plans open soon. Everything above keeps working on your current plan.
      </p>
    );
  }

  const upgradeTargets = (["pro", "pro_recall"] as const).filter((p) => p !== paidTier && !(paidTier === "pro_recall" && p === "pro"));

  return (
    <div style={{ marginTop: 18 }}>
      {error && (
        <div className="nv-banner nv-banner-bad" role="alert">
          {error}
        </div>
      )}
      {!hasSubscription && upgradeTargets.length > 0 && (
        <>
          <div className="nv-row" style={{ justifyContent: "space-between", marginBottom: 12 }}>
            <span className="nv-h2" style={{ fontSize: 15 }}>
              Upgrade
            </span>
            <div className="nv-seg" role="group" aria-label="Billing period">
              <button type="button" aria-pressed={interval === "month"} onClick={() => setInterval("month")}>
                Monthly
              </button>
              <button type="button" aria-pressed={interval === "year"} onClick={() => setInterval("year")}>
                Yearly · save 20%
              </button>
            </div>
          </div>
          <div className="nv-plans">
            {upgradeTargets.map((p) => (
              <div className="nv-plan" key={p}>
                <span className="nv-h2" style={{ fontSize: 15 }}>
                  {p === "pro" ? "Pro" : "Pro + Recall"}
                </span>
                <span className="nv-plan-price nv-tnum">{PRICES[p][interval]}</span>
                <span className="nv-dim">{p === "pro" ? "Unlimited answers, 300 tasks a month, voice." : "Pro, plus a private memory of your screen."}</span>
                <button
                  type="button"
                  className={`nv-btn ${p === "pro" ? "nv-btn-primary" : "nv-btn-secondary"} nv-btn-sm`}
                  disabled={busy !== null || !available[p][interval]}
                  onClick={() => billing({ action: "checkout", plan: p, interval }, p)}
                >
                  {busy === p ? "Opening checkout…" : available[p][interval] ? `Choose ${p === "pro" ? "Pro" : "Pro + Recall"}` : "Not available yet"}
                </button>
              </div>
            ))}
          </div>
        </>
      )}
      {hasCustomer && (
        <div className="nv-row" style={{ marginTop: 14 }}>
          <button type="button" className="nv-btn nv-btn-secondary nv-btn-sm" disabled={busy !== null} onClick={() => billing({ action: "portal" }, "portal")}>
            {busy === "portal" ? "Opening…" : "Manage billing"}
          </button>
          <span className="nv-dim">Change plan, update your card, see invoices, or cancel.</span>
        </div>
      )}
    </div>
  );
}

export function SignOutButton() {
  const [busy, setBusy] = useState(false);
  return (
    <button
      type="button"
      className="nv-btn nv-btn-secondary nv-btn-sm"
      disabled={busy}
      onClick={async () => {
        setBusy(true);
        const res = await fetch("/account/signout", {
          method: "POST",
          credentials: "same-origin",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ scope: "this" }),
        }).catch(() => null);
        const body = (await res?.json().catch(() => ({}))) as { redirect?: string } | undefined;
        window.location.assign(`${body?.redirect ?? "/auth/start?redirect=account"}&signed_out=1`);
      }}
    >
      {busy ? "Signing out…" : "Sign out"}
    </button>
  );
}

export function DeviceActions() {
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <div style={{ marginTop: 14 }}>
      {error && (
        <div className="nv-banner nv-banner-bad" role="alert">
          {error}
        </div>
      )}
      {!confirming ? (
        <button type="button" className="nv-btn nv-btn-secondary nv-btn-sm" onClick={() => setConfirming(true)}>
          Sign out everywhere
        </button>
      ) : (
        <div className="nv-row">
          <span className="nv-muted" style={{ fontSize: 14 }}>
            Every Mac and browser signs out within the hour, including this one.
          </span>
          <button
            type="button"
            className="nv-btn nv-btn-danger nv-btn-sm"
            disabled={busy}
            onClick={async () => {
              setBusy(true);
              const res = await accountFetch("/account/signout", { method: "POST", body: JSON.stringify({ scope: "everywhere" }) });
              if (res.ok) {
                window.location.assign("/auth/start?redirect=account&signed_out=1");
                return;
              }
              setBusy(false);
              setError(await errorMessage(res));
            }}
          >
            {busy ? "Signing out…" : "Sign out everywhere"}
          </button>
          <button type="button" className="nv-link" onClick={() => setConfirming(false)}>
            Cancel
          </button>
        </div>
      )}
    </div>
  );
}

export function ExportButton() {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <>
      <button
        type="button"
        className="nv-btn nv-btn-secondary nv-btn-sm"
        disabled={busy}
        onClick={async () => {
          setBusy(true);
          setError(null);
          const res = await accountFetch("/v1/account/export", { method: "GET" });
          setBusy(false);
          if (!res.ok) {
            setError(await errorMessage(res));
            return;
          }
          const text = await res.text();
          const blob = new Blob([text], { type: "application/json" });
          const a = document.createElement("a");
          a.href = URL.createObjectURL(blob);
          a.download = `navi-account-${new Date().toISOString().slice(0, 10)}.json`;
          document.body.appendChild(a);
          a.click();
          a.remove();
          setTimeout(() => URL.revokeObjectURL(a.href), 1000);
        }}
      >
        {busy ? "Preparing…" : "Export my data"}
      </button>
      <span className="nv-dim">A JSON file of everything Navi’s servers hold about you.</span>
      {error && (
        <div className="nv-banner nv-banner-bad" role="alert" style={{ width: "100%", marginTop: 10 }}>
          {error}
        </div>
      )}
    </>
  );
}

export function DangerZone({ email, hasSubscription }: { email: string; hasSubscription: boolean }) {
  const [open, setOpen] = useState(false);
  const [typed, setTyped] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const ready = typed.trim().toLowerCase() === "delete";

  return (
    <section className="nv-card" aria-labelledby="del-h" style={{ borderColor: "rgba(240,134,138,0.22)" }}>
      <div className="nv-card-head">
        <h2 className="nv-h2" id="del-h">
          Delete account
        </h2>
      </div>
      <p className="nv-muted" style={{ marginTop: 0 }}>
        Permanently deletes your Navi account and everything our servers hold about you
        {hasSubscription ? ", and cancels your subscription right away" : ""}. Navi on your Mac keeps its local data until you remove the app.
      </p>
      <button type="button" className="nv-btn nv-btn-danger nv-btn-sm" onClick={() => setOpen(true)}>
        Delete my account…
      </button>

      {open && (
        <div className="nv-dialog" role="dialog" aria-modal="true" aria-labelledby="del-dlg-h">
          <form
            className="nv-dialog-card nv-stack"
            onSubmit={async (e) => {
              e.preventDefault();
              if (!ready) return;
              setBusy(true);
              setError(null);
              const res = await accountFetch("/v1/account", { method: "DELETE" });
              if (res.status === 204) {
                window.location.assign("/account/deleted");
                return;
              }
              setBusy(false);
              setError(await errorMessage(res));
            }}
          >
            <h3 className="nv-h2" id="del-dlg-h">
              Delete {email}?
            </h3>
            <p className="nv-muted" style={{ margin: 0, fontSize: 14 }}>
              This can’t be undone.{hasSubscription ? " Your subscription is cancelled immediately, without a refund for the current period." : ""} Type{" "}
              <strong style={{ color: "var(--nv-fg)" }}>delete</strong> to confirm.
            </p>
            <input className="nv-input" aria-label="Type delete to confirm" autoFocus value={typed} onChange={(e) => setTyped(e.target.value)} disabled={busy} />
            {error && (
              <div className="nv-banner nv-banner-bad" role="alert" style={{ margin: 0 }}>
                {error}
              </div>
            )}
            <div className="nv-row" style={{ justifyContent: "flex-end" }}>
              <button type="button" className="nv-btn nv-btn-secondary nv-btn-sm" onClick={() => setOpen(false)} disabled={busy}>
                Keep my account
              </button>
              <button type="submit" className="nv-btn nv-btn-solid-danger nv-btn-sm" disabled={!ready || busy}>
                {busy ? "Deleting…" : "Delete forever"}
              </button>
            </div>
          </form>
        </div>
      )}
    </section>
  );
}
