import { Foot, Shell } from "../../auth/ui";

export const dynamic = "force-static";

/** Where /account lands after DELETE /v1/account succeeds. */
export default function AccountDeleted() {
  return (
    <Shell>
      <main className="nv-narrow">
        <h1 className="nv-h1">Your account is deleted</h1>
        <p className="nv-lede">
          Everything Navi’s servers held about you is gone, and every Mac and browser is signed out. Any subscription was cancelled.
        </p>
        <div className="nv-card">
          <p className="nv-muted" style={{ margin: 0 }}>
            Navi on your Mac keeps its own local data — settings, and Recall’s memory and notes if you used it. That never
            reached our servers; delete it from your Mac whenever you like.
          </p>
        </div>
        <Foot />
      </main>
    </Shell>
  );
}
