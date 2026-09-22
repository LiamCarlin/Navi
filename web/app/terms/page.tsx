import type { Metadata } from "next";
import { LegalPage } from "@/components/LegalPage";

export const metadata: Metadata = { title: "Terms — Navi" };

export default function Terms() {
  return (
    <LegalPage title="Terms">
      <p>
        This page is a placeholder while Navi is in private beta. The final terms will be published before
        the public launch.
      </p>
      <p>
        Beta builds are provided as-is. Subscriptions, when they open, are billed monthly or yearly and can
        be cancelled at any time from the app.
      </p>
    </LegalPage>
  );
}
