import type { Metadata } from "next";
import type { ReactNode } from "react";
import "./navi-ui.css";

export const metadata: Metadata = {
  title: "Sign in · Navi",
  robots: { index: false, follow: false },
  referrer: "no-referrer",
};

export default function AuthLayout({ children }: { children: ReactNode }) {
  return children;
}
