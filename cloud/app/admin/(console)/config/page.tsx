import { dateTime } from "@/lib/admin/format";
import { requireAdmin } from "@/lib/admin/guard";
import { CONFIG_KEY, FEATURE_SWITCHES, meConfig, MODEL_FEATURES, NOTICE_LEVELS, normalizeConfig } from "@/lib/config";
import { getDb } from "@/lib/db";
import { env } from "@/lib/env";
import { PLANS, TIERS } from "@/lib/plans";
import {
  addAdminAction,
  removeAdminAction,
  saveModelsAction,
  saveNoticeAction,
  saveQuotasAction,
  saveVersionsAction,
  toggleFeatureAction,
} from "../../actions";
import { ConfirmButton } from "../../_components/client";
import { Card, Flash, Hidden } from "../../_components/ui";
import s from "../../admin.module.css";

export const dynamic = "force-dynamic";

const FEATURE_HELP: Record<string, string> = {
  answers: "Streamed answers (X-Navi-Feature: answer)",
  tasks: "Computer-use tasks (task)",
  voice: "Spoken commands (voice)",
  recall: "Screen memory triage + digests (recall_*)",
};

const MODEL_HELP: Record<string, string> = {
  answer: "answers — e.g. claude-sonnet-5",
  task: "tasks + voice — Claude calls only (Jev is never overridden)",
  digest: "Recall digests — a claude-* or gemini-* id",
};

export default async function Config({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const me = await requireAdmin();
  const params = await searchParams;
  const db = await getDb();
  // Fresh from storage (not the 30 s cache) so the page shows what was just saved.
  const cfg = normalizeConfig(await db.adminGetConfig(CONFIG_KEY));
  const admins = await db.adminListAdmins().catch(() => []);

  return (
    <>
      <h1 className={s.h1}>Product config</h1>
      <p className={s.sub}>
        What the app sees in <code>GET /v1/me</code> and what the proxy enforces. Changes apply on this instance at once and on every
        other instance within 30 s.{cfg.updatedAt && <> Last saved {dateTime(cfg.updatedAt)} by {cfg.updatedBy}.</>}
      </p>
      <Flash params={params} />

      <div className={`${s.grid} ${s.cols2}`}>
        <Card title="Kill switches">
          {FEATURE_SWITCHES.map((f) => {
            const on = cfg.features[f];
            return (
              <div key={f} className={s.switch}>
                <div>
                  <div><strong>{f}</strong> <span className={on ? s.badgeGood : s.badgeBad}>{on ? "on" : "OFF"}</span></div>
                  <div className={s.muted}>{FEATURE_HELP[f]}</div>
                </div>
                <form action={toggleFeatureAction}>
                  <Hidden values={{ feature: f, on: on ? "0" : "1" }} />
                  {on ? (
                    <ConfirmButton className={s.btnDanger} message={`Switch ${f} OFF for every user? Calls return 503 feature_disabled.`}>Turn off</ConfirmButton>
                  ) : (
                    <button className={s.btnGood}>Turn on</button>
                  )}
                </form>
              </div>
            );
          })}
        </Card>

        <Card title="In-app notice">
          <form action={saveNoticeAction} className={s.stack}>
            <textarea className={s.textarea} name="message" defaultValue={cfg.notice?.message ?? ""} placeholder="e.g. Answers are slow right now — we're on it." maxLength={500} />
            <div className={s.row}>
              <select className={s.select} name="level" defaultValue={cfg.notice?.level ?? "info"}>
                {NOTICE_LEVELS.map((l) => <option key={l} value={l}>{l}</option>)}
              </select>
              <input className={s.inputWide} name="url" defaultValue={cfg.notice?.url ?? ""} placeholder="optional link (https://…)" />
            </div>
            <div className={s.row}>
              <button className={s.btnPrimary}>Publish notice</button>
              {cfg.notice && <button className={s.btn} name="clear" value="1">Clear</button>}
              {cfg.notice && <span className={s.muted}>id <code>{cfg.notice.id}</code></span>}
            </div>
          </form>
        </Card>
      </div>

      <div className={`${s.grid} ${s.cols2} ${s.section}`}>
        <Card title="App versions">
          <form action={saveVersionsAction} className={s.stack}>
            <label className={s.label}>Minimum app version — older apps get 426 upgrade_required on /v1/* (not /v1/me)
              <input className={s.input} name="minAppVersion" defaultValue={cfg.minAppVersion ?? ""} placeholder="e.g. 1.2.0 (blank = no minimum)" />
            </label>
            <label className={s.label}>Latest version — the app offers an update
              <input className={s.input} name="latestVersion" defaultValue={cfg.latestVersion ?? ""} placeholder="e.g. 1.3.0" />
            </label>
            <label className={s.label}>Download URL
              <input className={s.input} name="downloadURL" defaultValue={cfg.downloadURL ?? ""} placeholder="https://navi.app/download" />
            </label>
            <div><button className={s.btnPrimary}>Save versions</button></div>
          </form>
        </Card>

        <Card title="Model per feature">
          <form action={saveModelsAction} className={s.stack}>
            {MODEL_FEATURES.map((m) => (
              <label key={m} className={s.label}>{MODEL_HELP[m]}
                <input className={s.input} name={m} defaultValue={cfg.models[m] ?? ""} placeholder="pass through the app's model" />
              </label>
            ))}
            <div><button className={s.btnPrimary}>Save models</button></div>
          </form>
        </Card>
      </div>

      <div className={s.section}>
        <Card title="Quotas per tier">
          <form action={saveQuotasAction}>
            <table className={s.table}>
              <thead><tr><th>Tier</th><th>Answers / day</th><th>Tasks / day</th><th>Tasks / month</th></tr></thead>
              <tbody>
                {TIERS.map((t) => (
                  <tr key={t}>
                    <td><strong>{t}</strong></td>
                    {(["answersPerDay", "tasksPerDay", "tasksPerMonth"] as const).map((k) => {
                      const o = cfg.quotas[t]?.[k];
                      const def = PLANS[t].quotas[k];
                      return (
                        <td key={k}>
                          <input
                            className={s.inputSmall}
                            name={`${t}.${k}`}
                            defaultValue={o === undefined ? "" : o === null ? "unlimited" : String(o)}
                            placeholder={def == null ? "—" : String(def)}
                          />
                          <span className={s.muted}> default {def ?? "none"}</span>
                        </td>
                      );
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
            <p className={s.muted}>Blank = plan default (lib/plans.ts) · a number = that cap · “unlimited” = no cap. A daily task cap wins over a monthly one.</p>
            <button className={s.btnPrimary}>Save quotas</button>
          </form>
        </Card>
      </div>

      <div className={`${s.grid} ${s.cols2} ${s.section}`}>
        <Card title="What the app receives (/v1/me → config)">
          <pre className={s.details} style={{ margin: 0, whiteSpace: "pre-wrap" }}>{JSON.stringify(meConfig(cfg), null, 2)}</pre>
        </Card>

        <Card title="Admins">
          <table className={s.table}>
            <tbody>
              {env.adminEmails.map((e) => (
                <tr key={`env-${e}`}><td>{e}</td><td className={s.muted}>ADMIN_EMAILS (env)</td><td /></tr>
              ))}
              {admins.map((a) => (
                <tr key={a.email}>
                  <td>{a.email}</td>
                  <td className={s.muted}>added by {a.addedBy}</td>
                  <td className={s.num}>
                    {a.email !== me.email && (
                      <form action={removeAdminAction}><Hidden values={{ email: a.email }} /><ConfirmButton className={s.btnDanger} message={`Remove ${a.email} as admin?`}>Remove</ConfirmButton></form>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <form action={addAdminAction} className={s.row} style={{ marginTop: 10 }}>
            <input className={s.inputWide} type="email" name="email" placeholder="email to make admin" required />
            <button className={s.btn}>Add admin</button>
          </form>
        </Card>
      </div>
    </>
  );
}
