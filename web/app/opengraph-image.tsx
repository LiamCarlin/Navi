import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { ImageResponse } from "next/og";
import { FAR, MID, NEAR } from "@/lib/ridge";

export const runtime = "nodejs";
export const alt = "Navi: ⌘Space, but it does things.";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

const STAR =
  "M12 1.5c.6 5.4 4.1 9 9.5 10.5-5.4 1.5-8.9 5.1-9.5 10.5-.6-5.4-4.1-9-9.5-10.5C7.9 10.5 11.4 6.9 12 1.5z";
const HEADLINE = "Space, but it does things.";

type Font = { name: string; data: ArrayBuffer; style: "normal" | "italic"; weight: 500 | 600 };

/** A Google font, subset to `text`. Empty if offline: the default font is used instead. */
async function google(family: string, axes: string, name: string, weight: 500 | 600, text: string): Promise<Font[]> {
  try {
    const css = await (await fetch(`https://fonts.googleapis.com/css2?family=${family}:${axes}&text=${encodeURIComponent(text)}`)).text();
    const faces = [...css.matchAll(/font-style: (normal|italic);[\s\S]*?src: url\((.+?)\) format\('(?:opentype|truetype)'\)/g)];
    return await Promise.all(
      faces.map(async ([, style, url]) => ({ name, data: await (await fetch(url)).arrayBuffer(), style: style as "normal" | "italic", weight })),
    );
  } catch {
    return [];
  }
}

/** The hero as a card: sky, mountains, the headline, and the real ⌘Space bar rising out of the range. */
export default async function OpenGraphImage() {
  const [sans, serifFonts, poster] = await Promise.all([
    google("Geist", "wght@600", "Geist", 600, "Navi"),
    google("EB+Garamond", "ital,wght@0,500;1,500", "Garamond", 500, HEADLINE),
    readFile(join(process.cwd(), "public/video/demo-poster.jpg")),
  ]);
  // The first font is Satori's default, so the sans goes first.
  const fonts = [...sans, ...serifFonts];
  const posterSrc = `data:image/jpeg;base64,${poster.toString("base64")}`;
  const serif = serifFonts.length ? "Garamond" : "serif";

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          position: "relative",
          background: "linear-gradient(180deg, #2c7fdc 0%, #4b9be8 30%, #8cc1f0 55%, #cfe4f8 72%, #ffffff 92%)",
        }}
      >
        {/* sun */}
        <div
          style={{
            position: "absolute",
            left: 1004,
            top: 344,
            width: 72,
            height: 72,
            borderRadius: 999,
            background: "#fff",
            boxShadow: "0 0 60px 40px rgba(255,250,235,0.85), 0 0 160px 90px rgba(255,245,225,0.4)",
          }}
        />

        {/* mountains */}
        <svg width="1200" height="390" viewBox="0 130 1600 390" style={{ position: "absolute", left: 0, bottom: 0 }}>
          <defs>
            <linearGradient id="far" x1="0" y1="200" x2="0" y2="520" gradientUnits="userSpaceOnUse">
              <stop offset="0" stopColor="#dbe9fa" />
              <stop offset="1" stopColor="#b9d3f2" />
            </linearGradient>
            <linearGradient id="mid" x1="0" y1="120" x2="0" y2="520" gradientUnits="userSpaceOnUse">
              <stop offset="0" stopColor="#f4f8ff" />
              <stop offset="0.12" stopColor="#bcd6f6" />
              <stop offset="0.3" stopColor="#5d8fd8" />
              <stop offset="0.62" stopColor="#3f6fc0" />
              <stop offset="1" stopColor="#9bbfe9" />
            </linearGradient>
            <linearGradient id="mist" x1="0" y1="300" x2="0" y2="520" gradientUnits="userSpaceOnUse">
              <stop offset="0" stopColor="#ffffff" stopOpacity="0" />
              <stop offset="0.6" stopColor="#ffffff" stopOpacity="0.7" />
              <stop offset="1" stopColor="#ffffff" />
            </linearGradient>
          </defs>
          <path d={FAR} fill="url(#far)" />
          <path d={MID} fill="url(#mid)" />
          <rect x="0" y="300" width="1600" height="220" fill="url(#mist)" />
          <path d={NEAR} fill="#ffffff" fillOpacity="0.92" />
        </svg>

        {/* headline */}
        <div style={{ position: "absolute", left: 0, right: 0, top: 50, display: "flex", flexDirection: "column", alignItems: "center", color: "#fff" }}>
          <div style={{ display: "flex", alignItems: "center", gap: 10, fontFamily: "Geist", fontSize: 24, fontWeight: 600 }}>
            <div style={{ display: "flex", alignItems: "center", justifyContent: "center", width: 32, height: 32, borderRadius: 9, background: "#fff" }}>
              <svg width="20" height="20" viewBox="0 0 24 24">
                <path d={STAR} fill="#bf5af2" />
              </svg>
            </div>
            Navi
          </div>
          <div style={{ display: "flex", alignItems: "center", marginTop: 26, fontFamily: serif, fontWeight: 500, fontSize: 76, lineHeight: 1, letterSpacing: -1 }}>
            <div
              style={{
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                width: 64,
                height: 64,
                marginRight: 16,
                borderRadius: 13,
                background: "rgba(255,255,255,0.22)",
                border: "1.5px solid rgba(255,255,255,0.6)",
              }}
            >
              <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M9 9V6a3 3 0 1 0-3 3h12a3 3 0 1 0-3-3v12a3 3 0 1 0 3-3H6a3 3 0 1 0 3 3z" />
              </svg>
            </div>
            <span>Space, but it</span>
            <span style={{ fontStyle: "italic", marginLeft: 18, marginRight: 18 }}>does</span>
            <span>things.</span>
          </div>
        </div>

        {/* the real bar, rising out of the range */}
        <div
          style={{
            position: "absolute",
            left: 240,
            top: 250,
            width: 720,
            height: 450,
            display: "flex",
            borderRadius: 18,
            overflow: "hidden",
            border: "2px solid rgba(255,255,255,0.7)",
            boxShadow: "0 30px 80px rgba(20,40,90,0.45)",
          }}
        >
          <img src={posterSrc} width={720} height={450} alt="" style={{ objectFit: "cover" }} />
        </div>
      </div>
    ),
    { ...size, fonts: fonts.length ? fonts : undefined },
  );
}
