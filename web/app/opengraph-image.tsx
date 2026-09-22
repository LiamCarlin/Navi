import { ImageResponse } from "next/og";

export const runtime = "edge";
export const alt = "Navi — Say it. It’s done.";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

const STAR =
  "M12 1.5c.6 5.4 4.1 9 9.5 10.5-5.4 1.5-8.9 5.1-9.5 10.5-.6-5.4-4.1-9-9.5-10.5C7.9 10.5 11.4 6.9 12 1.5z";

function Star({ size, color }: { size: number; color: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24">
      <path d={STAR} fill={color} />
    </svg>
  );
}

function Check({ size }: { size: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="#000" strokeWidth="3.2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M5 12l5 5 9-10" />
    </svg>
  );
}

/** The MacBook with the voice island down, plus the headline. Flexbox only (Satori). */
export default function OpenGraphImage() {
  const steps = ["Opening Chrome", "Searching flights to Tokyo", "Comparing prices", "Picked $412 · ANA, Oct 14"];
  const bars = [8, 14, 18, 11, 16, 9, 13, 7];

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          alignItems: "center",
          background: "#0a0a0b",
          backgroundImage: "radial-gradient(50% 60% at 70% 40%, rgba(139,140,248,0.18), transparent 70%)",
          color: "#f4f4f5",
          fontFamily: "sans-serif",
          padding: "0 64px",
        }}
      >
        {/* Left: wordmark + headline */}
        <div style={{ display: "flex", flexDirection: "column", width: 470 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 10, fontSize: 26, fontWeight: 600 }}>
            <Star size={24} color="#8b8cf8" />
            Navi
          </div>
          <div style={{ display: "flex", flexDirection: "column", fontSize: 72, fontWeight: 600, letterSpacing: -3, lineHeight: 1.02, marginTop: 36 }}>
            <span>Say it.</span>
            <span>It’s done.</span>
          </div>
          <div style={{ display: "flex", fontSize: 24, color: "#a3a3ad", marginTop: 22, lineHeight: 1.4 }}>
            Opens apps, answers questions, and does things on your Mac — by keyboard or voice, in under a second.
          </div>
        </div>

        {/* Right: MacBook, lid only, island down */}
        <div style={{ display: "flex", flexDirection: "column", alignItems: "center", marginLeft: 36, width: 600 }}>
          <div
            style={{
              display: "flex",
              width: 600,
              height: 392,
              borderRadius: 22,
              background: "linear-gradient(180deg,#2d2d31,#1c1c1f)",
              padding: 5,
              boxShadow: "0 40px 90px rgba(0,0,0,0.7)",
            }}
          >
            <div style={{ display: "flex", flex: 1, borderRadius: 18, background: "#050506", padding: "12px 10px 12px" }}>
              <div
                style={{
                  display: "flex",
                  flex: 1,
                  flexDirection: "column",
                  alignItems: "center",
                  position: "relative",
                  borderRadius: 10,
                  overflow: "hidden",
                  backgroundImage:
                    "radial-gradient(70% 60% at 22% 105%, rgba(139,140,248,0.55), transparent 62%), radial-gradient(55% 45% at 88% 10%, rgba(120,90,220,0.35), transparent 60%), linear-gradient(165deg,#1b1b30 0%,#131324 45%,#0c0c16 100%)",
                }}
              >
                {/* Menu bar */}
                <div
                  style={{
                    display: "flex",
                    width: "100%",
                    height: 22,
                    alignItems: "center",
                    padding: "0 12px",
                    fontSize: 11,
                    color: "rgba(255,255,255,0.8)",
                    background: "rgba(0,0,0,0.25)",
                  }}
                >
                  <span style={{ fontWeight: 600 }}>Finder</span>
                  <span style={{ marginLeft: 12 }}>File</span>
                  <span style={{ marginLeft: 12 }}>Edit</span>
                  <span style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: 4 }}>
                    <Star size={11} color="#8b8cf8" />
                    Navi
                  </span>
                  <span style={{ marginLeft: 12 }}>Mon 9:41</span>
                </div>

                {/* Island (hanging from the notch, which is drawn on top) */}
                <div
                  style={{
                    display: "flex",
                    flexDirection: "column",
                    width: 330,
                    marginTop: -22,
                    padding: "38px 16px 14px",
                    borderRadius: "0 0 22px 22px",
                    background: "#000",
                    boxShadow: "0 18px 50px rgba(0,0,0,0.8)",
                  }}
                >
                  <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                    <div
                      style={{
                        display: "flex",
                        width: 24,
                        height: 24,
                        borderRadius: 12,
                        background: "rgba(139,140,248,0.16)",
                        alignItems: "center",
                        justifyContent: "center",
                      }}
                    >
                      <Star size={12} color="#8b8cf8" />
                    </div>
                    <div style={{ display: "flex", alignItems: "center", gap: 3, height: 18 }}>
                      {bars.map((h, i) => (
                        <div key={i} style={{ display: "flex", width: 3, height: h, borderRadius: 2, background: "#8b8cf8" }} />
                      ))}
                    </div>
                    <span style={{ marginLeft: "auto", fontSize: 11, color: "#6e6e78" }}>Done</span>
                  </div>
                  <div style={{ display: "flex", fontSize: 14, marginTop: 10, lineHeight: 1.35, color: "#fff" }}>
                    “open chrome, search flights to tokyo, and pick the cheapest”
                  </div>
                  <div
                    style={{
                      display: "flex",
                      flexDirection: "column",
                      gap: 6,
                      marginTop: 10,
                      paddingTop: 8,
                      borderTop: "1px solid rgba(255,255,255,0.1)",
                    }}
                  >
                    {steps.map((s) => (
                      <div key={s} style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 12.5, color: "rgba(255,255,255,0.85)" }}>
                        <div
                          style={{
                            display: "flex",
                            width: 14,
                            height: 14,
                            borderRadius: 7,
                            background: "#8b8cf8",
                            alignItems: "center",
                            justifyContent: "center",
                          }}
                        >
                          <Check size={9} />
                        </div>
                        {s}
                      </div>
                    ))}
                  </div>
                </div>

                {/* Notch */}
                <div
                  style={{
                    display: "flex",
                    position: "absolute",
                    top: 0,
                    left: 227,
                    width: 112,
                    height: 26,
                    borderRadius: "0 0 11px 11px",
                    background: "#050506",
                  }}
                />

                {/* Dock */}
                <div
                  style={{
                    display: "flex",
                    position: "absolute",
                    bottom: 8,
                    left: 165,
                    gap: 6,
                    padding: 5,
                    borderRadius: 12,
                    background: "rgba(255,255,255,0.1)",
                    border: "1px solid rgba(255,255,255,0.1)",
                  }}
                >
                  {["#3b82f6", "#22c55e", "#f59e0b", "#ef4444", "#a855f7", "#14b8a6", "#64748b"].map((c) => (
                    <div key={c} style={{ display: "flex", width: 22, height: 22, borderRadius: 6, background: c }} />
                  ))}
                </div>
              </div>
            </div>
          </div>
          {/* Base hint */}
          <div style={{ display: "flex", width: 640, height: 14, borderRadius: "0 0 10px 10px", background: "linear-gradient(180deg,#232326,#151517)" }} />
        </div>
      </div>
    ),
    { ...size },
  );
}
