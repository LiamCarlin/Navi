"use client";

/**
 * Where a signup came from. A CTA that only links to the form (pricing) records its source here;
 * the form reads and clears it. `?ref=` on the URL is kept for the session so referrals attribute.
 * Every storage access is guarded: private windows and blocked storage must not break the form.
 */
const SOURCE_KEY = "navi-source";
const REF_KEY = "navi-ref";
const JOINED_KEY = "navi-joined";
const DISMISSED_KEY = "navi-cta-dismissed";

function get(store: Storage | null, key: string): string | null {
  try {
    return store?.getItem(key) ?? null;
  } catch {
    return null;
  }
}
function set(store: Storage | null, key: string, value: string | null) {
  try {
    if (value === null) store?.removeItem(key);
    else store?.setItem(key, value);
  } catch {}
}
const session = () => (typeof window === "undefined" ? null : window.sessionStorage);
const local = () => (typeof window === "undefined" ? null : window.localStorage);

export function setSource(source: string) {
  set(session(), SOURCE_KEY, source);
}

/** The pending source set by a CTA, else `fallback`. Clears it. */
export function takeSource(fallback: string): string {
  const s = get(session(), SOURCE_KEY);
  if (s) set(session(), SOURCE_KEY, null);
  return s ?? fallback;
}

/** `?ref=` from the URL (remembered for the session). */
export function getRef(): string | null {
  if (typeof window === "undefined") return null;
  const fromUrl = new URLSearchParams(window.location.search).get("ref");
  if (fromUrl && /^[a-z0-9]{1,16}$/i.test(fromUrl)) {
    set(session(), REF_KEY, fromUrl);
    return fromUrl;
  }
  return get(session(), REF_KEY);
}

export const joined = {
  get: () => get(local(), JOINED_KEY) === "1",
  set: () => set(local(), JOINED_KEY, "1"),
};
export const ctaDismissed = {
  get: () => get(local(), DISMISSED_KEY) === "1",
  set: () => set(local(), DISMISSED_KEY, "1"),
};
