export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * GET /billing/return?status=success|cancel|portal — Stripe needs http(s) return URLs,
 * so this page bounces the browser to navi://billing/success or navi://billing/cancel
 * (the URLs the app listens for) and leaves a plain "back to Navi" link behind.
 */
export function GET(req: Request): Response {
  const status = new URL(req.url).searchParams.get("status");
  const target = status === "cancel" ? "navi://billing/cancel" : "navi://billing/success";
  const title = status === "cancel" ? "No changes made" : status === "portal" ? "Billing updated" : "You're all set";
  const blurb = status === "cancel" ? "Your plan is unchanged." : "Navi will pick up your new plan in a moment.";
  const html = `<!doctype html><meta charset="utf-8"><title>${title} · Navi</title>
<meta http-equiv="refresh" content="0;url=${target}">
<body style="margin:0;background:#0b0b0d;color:#f2f2f4;font-family:-apple-system,system-ui,sans-serif">
<main style="max-width:480px;margin:18vh auto;padding:0 24px">
<div style="font-size:13px;letter-spacing:2px;text-transform:uppercase;color:#7c7c86">✦ Navi</div>
<h1 style="font-size:26px;font-weight:600;margin:10px 0 6px">${title}</h1>
<p style="color:#9a9aa3;line-height:1.5">${blurb}</p>
<p><a href="${target}" style="color:#f2f2f4">Back to Navi →</a></p>
</main><script>location.replace(${JSON.stringify(target)})</script>`;
  return new Response(html, { status: 200, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
}
