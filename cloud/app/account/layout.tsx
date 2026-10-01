import type { Metadata } from "next";
import type { ReactNode } from "react";
import "../auth/navi-ui.css";

export const metadata: Metadata = {
  title: "Your account · Navi",
  robots: { index: false, follow: false },
  referrer: "no-referrer",
};

export default function AccountLayout({ children }: { children: ReactNode }) {
  return children;
}
