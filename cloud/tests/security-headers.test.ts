import { describe, expect, it } from "vitest";
import nextConfig, { ADMIN_CONTENT_SECURITY_POLICY, CONTENT_SECURITY_POLICY } from "@/next.config";

describe("security headers (next.config.ts)", () => {
  it("apply to every path, HTML pages included", async () => {
    const rules = await nextConfig.headers!();
    const all = rules.find((r) => r.source === "/:path*");
    expect(all).toBeTruthy();
    const keys = all!.headers.map((h) => h.key);
    expect(keys).toEqual(expect.arrayContaining(["Content-Security-Policy", "X-Frame-Options", "X-Content-Type-Options", "Referrer-Policy"]));
  });

  it("forbid framing and third-party connections", () => {
    expect(CONTENT_SECURITY_POLICY).toContain("frame-ancestors 'none'");
    expect(CONTENT_SECURITY_POLICY).toMatch(/connect-src 'self'(;| ws:)/);
    expect(CONTENT_SECURITY_POLICY).toContain("object-src 'none'");
    expect(CONTENT_SECURITY_POLICY).toContain("base-uri 'none'");
  });

  it("/admin overrides only connect-src (its login uses the Supabase browser client)", async () => {
    const rules = await nextConfig.headers!();
    const admin = rules.find((r) => r.source === "/admin/:path*");
    expect(admin?.headers).toEqual([{ key: "Content-Security-Policy", value: ADMIN_CONTENT_SECURITY_POLICY }]);
    expect(rules.indexOf(admin!)).toBeGreaterThan(rules.findIndex((r) => r.source === "/:path*"));
    expect(ADMIN_CONTENT_SECURITY_POLICY).toContain("frame-ancestors 'none'");
    const strip = (p: string) => p.split("; ").filter((d) => !d.startsWith("connect-src")).join("; ");
    expect(strip(ADMIN_CONTENT_SECURITY_POLICY)).toBe(strip(CONTENT_SECURITY_POLICY));
  });
});
