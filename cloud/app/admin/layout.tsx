import type { Metadata } from "next";
import type { ReactNode } from "react";
import s from "./admin.module.css";

export const metadata: Metadata = {
  title: "Navi Admin",
  robots: { index: false, follow: false },
};

/** Styling only. The guard lives in (console)/layout.tsx and in every page/action. */
export default function AdminRoot({ children }: { children: ReactNode }) {
  return <div className={s.root}>{children}</div>;
}
