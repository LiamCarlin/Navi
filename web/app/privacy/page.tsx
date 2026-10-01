import type { Metadata } from "next";
import { LegalPage } from "@/components/LegalPage";

export const metadata: Metadata = {
  title: "Privacy — Navi",
  description: "What Navi keeps on your Mac, what it sends to answer you, and how to delete it.",
};

const UPDATED = "October 1, 2026";
const CONTACT = "hello@buildnavi.com";

function H({ children }: { children: React.ReactNode }) {
  return <h2 className="pt-6 text-lg font-semibold text-fg">{children}</h2>;
}

function List({ children }: { children: React.ReactNode }) {
  return <ul className="list-disc space-y-2 pl-5">{children}</ul>;
}

function B({ children }: { children: React.ReactNode }) {
  return <strong className="font-medium text-fg">{children}</strong>;
}

export default function Privacy() {
  return (
    <LegalPage title="Privacy">
      <p className="text-sm">Last updated {UPDATED}</p>
      <p>
        Navi is a Mac app. Most of what it knows about you stays on your Mac. To answer a question or do a task, it
        has to send some of what you asked, and some of what is on your screen, to AI services. This page says
        exactly what, when, and what happens to it.
      </p>

      <H>The short version</H>
      <List>
        <li>We don’t sell your data, show ads, or use your content to train AI models.</li>
        <li>
          Your requests pass through Navi’s servers to the AI services that answer them. Our servers keep your
          account and a count of what you used — not the content.
        </li>
        <li>
          Recall (screen memory) is off until you turn it on. What it remembers is stored on your Mac. To decide what
          is worth remembering and to write summaries, it sends screen text — and, for summaries, up to two small
          screenshots — to AI services.
        </li>
        <li>Voice is recognised on your Mac. Audio never leaves it.</li>
        <li>You can delete everything Navi stored on your Mac from Settings, and your account by emailing us.</li>
      </List>

      <H>What stays on your Mac</H>
      <p>Navi stores these in your user folder, readable only by your macOS account:</p>
      <List>
        <li>
          <B>Screen memory</B> (if you turn Recall on): for each remembered moment, the text read from your screen
          on your Mac, the app, window title and page address; small screenshots if “Keep screenshots” is on; and
          the summaries made from them. Kept 30 days by default — you can choose 7, 30 or 90 days, or forever.
        </li>
        <li>
          <B>Your journal</B>: Recall writes summary notes into a folder you choose (by default “Navi Vault” in your
          home folder). They follow the same retention unless you switch that off. Notes you write there yourself
          are never changed or deleted by Navi.
        </li>
        <li>
          <B>What worked in past tasks</B>: short task descriptions and the buttons that worked, so Navi can repeat
          what succeeded. Never the text it typed for you.
        </li>
        <li>
          <B>Recent searches</B>: your last 50 searches in the Navi bar, to rank results.
        </li>
        <li>
          <B>Task logs</B>: off unless you turn on “Keep task logs for troubleshooting”. If you do, step-by-step
          records of tasks (including what was on screen and typed, with card, ID and similar numbers removed) are
          kept on your Mac for 7 days. They are never uploaded.
        </li>
      </List>

      <H>What Recall never captures</H>
      <p>
        A locked or sleeping screen, the screen saver, another user’s session, password managers and other apps
        you exclude (their windows are cut out of every snapshot), sites you exclude, private and incognito browser
        windows in browsers that report them, a focused password field, and Navi itself. Moments showing personal
        details you choose to block — such as card numbers, government ID numbers, dates of birth, or patient
        portals — are recognised on your Mac and kept only as “an app was open at this time”; nothing from them is
        sent anywhere. Passwords and one-time codes are always blocked.
      </p>

      <H>What leaves your Mac, and why</H>
      <List>
        <li>
          <B>Questions and commands.</B> What you type or say, the app you are in and its window title, and — when
          your question refers to them — your selected text, clipboard, or relevant screen memories. Used to decide
          what you meant and to write the answer.
        </li>
        <li>
          <B>Tasks Navi does for you.</B> At each step, the text and controls of the app Navi is working in, and
          sometimes a screenshot of that window. Used to choose the next step and write what you asked for.
        </li>
        <li>
          <B>Recall.</B> For each moment it captures, up to a few thousand characters of the screen’s text with the
          app, window title and page address, to decide whether it is worth remembering. For moments that are, that
          text and up to two small screenshots, to write the summary. Personal details you block are removed first.
        </li>
        <li>
          <B>Voice.</B> Only the words of a command, after your Mac has turned speech into text.
        </li>
      </List>
      <p>
        These requests go to Navi’s servers, which forward them to AI service providers who process them on our
        behalf to produce the response. We don’t store the content of your requests or the responses. Our providers
        don’t use it to train their models and may keep it briefly to operate and secure their service, under their
        agreements with us.
      </p>

      <H>What Navi’s servers keep</H>
      <List>
        <li>
          <B>Your account</B>: your email address, how you sign in, your plan, and your trial and subscription status.
        </li>
        <li>
          <B>Usage counts</B>: which feature you used (an answer, a task, Recall…), when, and its estimated cost — to
          apply your plan’s limits. Never what you asked or what was on your screen.
        </li>
        <li>
          <B>Payments</B> are handled by our payment processor. We see your subscription status and a customer
          reference, never your card number.
        </li>
        <li>
          <B>Server logs</B>: like any web service, our hosting provider records technical request data (such as IP
          address, time and the address requested) for a short time to keep the service running and secure.
        </li>
        <li>
          <B>Waitlist</B>: your email, where you came from, the note you left (if any) and when you signed up.
        </li>
      </List>

      <H>The website</H>
      <p>
        buildnavi.com uses no analytics, ads or tracking cookies. It remembers your light/dark choice and how you arrived
        (for example a referral link) in your browser’s storage.
      </p>

      <H>Deleting your data</H>
      <List>
        <li>
          <B>On your Mac</B>: Settings → Privacy &amp; Data → “Delete everything Navi has stored” removes screen
          memory, its screenshots, the journal notes Navi wrote, task logs, task history and recent searches. Your
          own notes are kept.
        </li>
        <li>
          <B>Your account</B>: email{" "}
          <a className="text-accent hover:underline" href={`mailto:${CONTACT}`}>
            {CONTACT}
          </a>{" "}
          from the address you sign in with. We delete your account, plan and usage records within 30 days. Our
          payment processor keeps billing records as the law requires.
        </li>
        <li>
          <B>The waitlist</B>: email us and we’ll remove you.
        </li>
      </List>

      <H>Children</H>
      <p>Navi is not meant for children under 13, and we don’t knowingly collect their data.</p>

      <H>Changes</H>
      <p>
        If we change what Navi collects or sends, we’ll update this page and the date above, and tell you in the app
        before the change applies to you.
      </p>

      <H>Contact</H>
      <p>
        Questions or requests:{" "}
        <a className="text-accent hover:underline" href={`mailto:${CONTACT}`}>
          {CONTACT}
        </a>
        .
      </p>
    </LegalPage>
  );
}
