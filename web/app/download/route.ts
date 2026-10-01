import { NextResponse } from "next/server";

/** The DMG of the latest published GitHub Release (`scripts/publish-release.sh`). */
const LATEST_DMG = "https://github.com/LiamCarlin/Navi/releases/latest/download/Navi.dmg";

const CLOUD = process.env.NEXT_PUBLIC_NAVI_CLOUD_URL?.replace(/\/+$/, "");
const SIGNUPS_OPEN = process.env.NEXT_PUBLIC_SIGNUPS_OPEN === "1" && Boolean(CLOUD);

/**
 * buildnavi.com/download — one stable link for videos, posts and emails.
 * While the site is in waitlist mode it lands on the waitlist; once sign-ups are open it
 * starts the DMG download. Temporary redirects, so browsers never cache the waitlist hop.
 */
export function GET(request: Request) {
  const target = SIGNUPS_OPEN ? LATEST_DMG : new URL("/#waitlist", request.url).toString();
  return NextResponse.redirect(target, 307);
}
