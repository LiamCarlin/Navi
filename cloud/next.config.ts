import type { NextConfig } from "next";

// MARK: account — security headers (every response; they matter on the HTML pages:
// /auth/start, /account, /billing/return). The pages talk only to this origin — sign-in calls
// to Supabase happen server-side — so connect-src is 'self'. Next's App Router inlines its
// bootstrap scripts, hence 'unsafe-inline' for scripts (no third-party script is ever loaded).
const isDev = process.env.NODE_ENV !== "production";

function csp(connectExtra: string[] = []): string {
  return [
    "default-src 'self'",
    `script-src 'self' 'unsafe-inline'${isDev ? " 'unsafe-eval'" : ""}`,
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob:",
    "font-src 'self' data:",
    ["connect-src 'self'", ...connectExtra, ...(isDev ? ["ws:", "wss:"] : [])].join(" "),
    "frame-ancestors 'none'",
    "frame-src 'none'",
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'self'",
    ...(isDev ? [] : ["upgrade-insecure-requests"]),
  ].join("; ");
}

export const CONTENT_SECURITY_POLICY = csp();

/** The Supabase project origin (build-time env), or null when unset / not a URL. */
function supabaseOrigin(): string | null {
  const raw = process.env.SUPABASE_URL ?? process.env.NEXT_PUBLIC_SUPABASE_URL;
  try { return raw ? new URL(raw).origin : null; } catch { return null; }
}

/**
 * /admin/login signs in with the Supabase browser client (magic link / Google, PKCE), so the
 * console's pages may also connect to the project's own origin — and nothing else.
 */
const adminOrigin = supabaseOrigin();
export const ADMIN_CONTENT_SECURITY_POLICY = csp(adminOrigin ? [adminOrigin] : []);

export const SECURITY_HEADERS: { key: string; value: string }[] = [
  { key: "Content-Security-Policy", value: CONTENT_SECURITY_POLICY },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "Referrer-Policy", value: "no-referrer" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()" },
  { key: "Cross-Origin-Opener-Policy", value: "same-origin" },
  // Two years, subdomains included. Only sent over https (browsers ignore it on http anyway).
  ...(isDev ? [] : [{ key: "Strict-Transport-Security", value: "max-age=63072000; includeSubDomains" }]),
];

const nextConfig: NextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  async headers() {
    // Later entries win for the same header key, so /admin's CSP overrides the global one.
    return [
      { source: "/:path*", headers: SECURITY_HEADERS },
      { source: "/admin/:path*", headers: [{ key: "Content-Security-Policy", value: ADMIN_CONTENT_SECURITY_POLICY }] },
    ];
  },
};

export default nextConfig;
