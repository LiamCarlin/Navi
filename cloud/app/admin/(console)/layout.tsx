import type { ReactNode } from "react";
import { requireAdmin } from "@/lib/admin/guard";
import { env } from "@/lib/env";
import { NavLink } from "../_components/client";
import s from "../admin.module.css";

export const dynamic = "force-dynamic";

/** Every console page sits under this guard (and each page/action checks again). */
export default async function ConsoleLayout({ children }: { children: ReactNode }) {
  const who = await requireAdmin();
  return (
    <div className={s.shell}>
      <nav className={s.nav} aria-label="Admin">
        <div className={s.brand}>✦ Navi <span>Admin</span></div>
        <NavLink href="/admin">Overview</NavLink>
        <NavLink href="/admin/users">Users</NavLink>
        <NavLink href="/admin/keys">Keys</NavLink>
        <NavLink href="/admin/config">Product config</NavLink>
        <NavLink href="/admin/waitlist">Waitlist</NavLink>
        <NavLink href="/admin/audit">Audit log</NavLink>
        <div className={s.navFoot}>
          <div>{who.email}</div>
          <div style={{ margin: "4px 0 8px" }}>
            <span className={env.dbDriver === "memory" ? s.badgeWarn : s.badge}>{env.dbDriver}</span>{" "}
            {env.mockUpstream && <span className={s.badgeWarn}>mock upstream</span>}
          </div>
          <form method="post" action="/admin/auth/logout">
            <button className={s.btn} type="submit">Sign out</button>
          </form>
        </div>
      </nav>
      <main className={s.main}>{children}</main>
    </div>
  );
}
