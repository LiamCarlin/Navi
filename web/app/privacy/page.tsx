import type { Metadata } from "next";
import { LegalPage } from "@/components/LegalPage";

export const metadata: Metadata = { title: "Privacy — Navi" };

export default function Privacy() {
  return (
    <LegalPage title="Privacy">
      <p>
        This page is a placeholder while Navi is in private beta. The final policy will be published before
        the public launch.
      </p>
      <p>
        In short: what you type into Navi is sent to Navi’s servers only to answer you or run the task you
        asked for. Recall is opt-in; it reads your screen on your Mac, drops anything sensitive before storing
        it, and writes notes to a folder you own. Frames never leave your Mac; only short summaries do.
      </p>
      <p>The waitlist stores your email and the note you leave, and nothing else. Ask and we’ll delete it.</p>
    </LegalPage>
  );
}
