import { ago, dateTime } from "@/lib/admin/format";
import { requireAdmin } from "@/lib/admin/guard";
import { getDb } from "@/lib/db";
import { env } from "@/lib/env";
import { keysSecretConfigured, keyStatuses } from "@/lib/keys";
import { removeKeyAction, setKeyAction, testKeyAction } from "../../actions";
import { ConfirmButton } from "../../_components/client";
import { Flash, Hidden } from "../../_components/ui";
import s from "../../admin.module.css";

export const dynamic = "force-dynamic";

export default async function Keys({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  await requireAdmin();
  const params = await searchParams;
  const db = await getDb();
  const keys = await keyStatuses(db);
  const canStore = keysSecretConfigured();
  const now = new Date();

  return (
    <>
      <h1 className={s.h1}>Vendor keys</h1>
      <p className={s.sub}>
        The keys Navi Cloud uses to call its vendors. A key stored here wins over the env var; remove it to fall back.
        Stored keys are AES-256-GCM encrypted; this page only ever shows the last four characters.
      </p>
      <Flash params={params} />
      {!canStore && (
        <div className={s.banner}>
          <strong>NAVI_KEYS_SECRET is not set</strong> (or shorter than 32 characters), so keys can&apos;t be stored here — the env vars are used.
          Generate one with <code>openssl rand -base64 48</code> and add it to the deployment&apos;s environment.
        </div>
      )}
      {env.mockUpstream && <div className={s.banner}>MOCK_UPSTREAM is on: the proxy answers with canned responses and doesn&apos;t use these keys. “Test” still makes a real call.</div>}

      <div className={s.stack}>
        {keys.map((k) => (
          <section key={k.provider} className={s.card}>
            <div className={s.rowBetween}>
              <div>
                <div className={s.h2} style={{ marginBottom: 2 }}>
                  {k.label}{" "}
                  <span className={k.source === "database" ? s.badgeGood : k.source === "env" ? s.badgeInfo : s.badgeBad}>
                    {k.source === "database" ? "database" : k.source === "env" ? `env · ${k.envVar}` : "not configured"}
                  </span>{" "}
                  {k.dbUnreadable && <span className={s.badgeBad}>stored key unreadable — NAVI_KEYS_SECRET changed?</span>}
                </div>
                <div className={s.muted}>{k.purpose}</div>
              </div>
              <div className={s.row}>
                <form action={testKeyAction}><Hidden values={{ provider: k.provider }} /><button className={s.btn} disabled={k.source === "none"}>Test</button></form>
                {k.dbPresent && (
                  <form action={removeKeyAction}>
                    <Hidden values={{ provider: k.provider }} />
                    <ConfirmButton className={s.btnDanger} message={`Remove the stored ${k.label} key? The proxy falls back to ${k.envVar}${k.envPresent ? "" : " (which is not set!)"}.`}>Remove</ConfirmButton>
                  </form>
                )}
              </div>
            </div>
            <dl className={s.kv} style={{ marginTop: 10 }}>
              <dt>Key in use</dt><dd className={s.mono}>{k.masked}{k.source === "database" && k.envPresent ? <span className={s.muted}> (env var also set, unused)</span> : null}</dd>
              <dt>Last rotated</dt><dd>{k.rotatedAt ? `${dateTime(k.rotatedAt)} by ${k.rotatedBy ?? "?"}` : <span className={s.muted}>{k.source === "env" ? "managed in env" : "—"}</span>}</dd>
              <dt>Last used</dt><dd>{k.lastUsedAt ? `${ago(k.lastUsedAt, now)} (${dateTime(k.lastUsedAt)})` : <span className={s.muted}>not recorded yet</span>}</dd>
              <dt>Last test</dt>
              <dd>
                {k.lastTestAt ? (
                  <>
                    <span className={k.lastTestOk ? s.badgeGood : s.badgeBad}>{k.lastTestOk ? "OK" : "failed"}</span>{" "}
                    {k.lastTestLatencyMs != null && `${k.lastTestLatencyMs} ms · `}{ago(k.lastTestAt, now)}
                    {k.lastTestError && <div className={s.details}>{k.lastTestError}</div>}
                  </>
                ) : (
                  <span className={s.muted}>never</span>
                )}
              </dd>
            </dl>
            <form action={setKeyAction} className={s.row} style={{ marginTop: 10 }}>
              <Hidden values={{ provider: k.provider, rotating: k.dbPresent ? "1" : "0" }} />
              <input className={s.inputWide} type="password" name="key" placeholder={k.dbPresent ? "paste the new key to rotate" : `paste a ${k.label} key to store it here`} autoComplete="off" required disabled={!canStore} />
              <button className={s.btnPrimary} disabled={!canStore}>{k.dbPresent ? "Rotate" : "Store"}</button>
            </form>
          </section>
        ))}
      </div>
      <p className={s.muted} style={{ marginTop: 14 }}>
        The proxy caches the key for up to 60 s per server instance; a rotation reaches every instance within a minute. Jev uses the TypeSafe key
        when one is set, else the AI Gateway key.
      </p>
    </>
  );
}
