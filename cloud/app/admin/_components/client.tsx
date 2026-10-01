"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { ReactNode } from "react";
import s from "../admin.module.css";

export function NavLink({ href, children }: { href: string; children: ReactNode }) {
  const path = usePathname();
  const active = href === "/admin" ? path === "/admin" : path === href || path.startsWith(`${href}/`);
  return (
    <Link href={href} className={active ? s.navLinkActive + " " + s.navLink : s.navLink} aria-current={active ? "page" : undefined}>
      {children}
    </Link>
  );
}

/** A submit button that asks first. Without JS the form still submits (server checks stand). */
export function ConfirmButton({ message, className, children }: { message: string; className?: string; children: ReactNode }) {
  return (
    <button
      type="submit"
      className={className ?? s.btn}
      onClick={(e) => {
        if (!window.confirm(message)) e.preventDefault();
      }}
    >
      {children}
    </button>
  );
}
