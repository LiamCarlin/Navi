import { ImageResponse } from "next/og";

export const runtime = "edge";
export const alt = "Navi — Press ⌘Space. Say what you want.";
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

/* The default OG font has no ⌘ or ⏎ glyphs, so both are drawn as strokes. */
function Command({ size, color }: { size: number; color: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M15 6v12a3 3 0 1 0 3-3H6a3 3 0 1 0 3 3V6a3 3 0 1 0-3 3h12a3 3 0 1 0-3-3" />
    </svg>
  );
}

function Return({ size, color }: { size: number; color: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M9 10l-5 5 5 5" />
      <path d="M20 4v7a4 4 0 0 1-4 4H4" />
    </svg>
  );
}

export default function OpenGraphImage() {
  const rows = [
    { title: "Maps", kind: "App", hint: "Open", bg: "linear-gradient(135deg,#34d399,#0d9488)", active: true },
    { title: "Directions home", kind: "Maps", hint: "Open", bg: "linear-gradient(135deg,#71717a,#3f3f46)", active: false },
    { title: "Ask Navi", kind: "Answer", hint: "Ask", bg: "linear-gradient(135deg,#8b8cf8,#6f9cff)", active: false },
  ];

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          background: "#07070b",
          backgroundImage:
            "radial-gradient(60% 50% at 50% 0%, rgba(139,140,248,0.35), transparent 70%)",
          color: "#f2f2f7",
          fontFamily: "sans-serif",
          position: "relative",
        }}
      >
        <div
          style={{
            position: "absolute",
            top: 44,
            left: 56,
            display: "flex",
            alignItems: "center",
            gap: 12,
            fontSize: 28,
            fontWeight: 600,
          }}
        >
          <Star size={26} color="#8b8cf8" />
          Navi
        </div>

        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 14,
            fontSize: 58,
            fontWeight: 600,
            letterSpacing: -2,
            marginTop: 20,
          }}
        >
          <span>Press</span>
          <span
            style={{
              display: "flex",
              alignItems: "center",
              gap: 4,
              padding: "0 14px",
              borderRadius: 16,
              border: "1px solid rgba(255,255,255,0.16)",
              background: "rgba(255,255,255,0.06)",
            }}
          >
            <Command size={44} color="#8b8cf8" />
            <span>Space</span>
          </span>
          <span style={{ marginLeft: -10 }}>. Say what you want.</span>
        </div>
        <div style={{ display: "flex", fontSize: 26, color: "#a1a1b3", marginTop: 14 }}>
          Opens apps, answers questions, does things on your Mac — in under a second.
        </div>

        <div
          style={{
            display: "flex",
            flexDirection: "column",
            width: 680,
            marginTop: 48,
            borderRadius: 20,
            background: "rgba(24,24,34,0.9)",
            border: "1px solid rgba(139,140,248,0.45)",
            boxShadow: "0 40px 90px rgba(0,0,0,0.7)",
            overflow: "hidden",
          }}
        >
          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: 14,
              height: 64,
              padding: "0 22px",
              fontSize: 22,
              borderBottom: "1px solid rgba(255,255,255,0.08)",
            }}
          >
            <Star size={22} color="#8b8cf8" />
            <div style={{ display: "flex", flex: 1 }}>Open Maps</div>
            <div
              style={{
                display: "flex",
                alignItems: "center",
                gap: 5,
                padding: "3px 9px",
                borderRadius: 7,
                border: "1px solid rgba(255,255,255,0.16)",
                background: "rgba(255,255,255,0.06)",
                fontSize: 14,
                color: "#a1a1b3",
              }}
            >
              <Command size={13} color="#a1a1b3" />
              Space
            </div>
          </div>
          <div style={{ display: "flex", flexDirection: "column", padding: 8 }}>
            {rows.map((r) => (
              <div
                key={r.title}
                style={{
                  display: "flex",
                  alignItems: "center",
                  gap: 14,
                  padding: "10px 14px",
                  borderRadius: 12,
                  background: r.active ? "rgba(139,140,248,0.16)" : "transparent",
                  color: r.active ? "#f2f2f7" : "#a1a1b3",
                  fontSize: 18,
                }}
              >
                <div style={{ display: "flex", width: 34, height: 34, borderRadius: 9, backgroundImage: r.bg }} />
                <div style={{ display: "flex", flexDirection: "column", flex: 1 }}>
                  <div style={{ display: "flex" }}>{r.title}</div>
                  <div style={{ display: "flex", fontSize: 13, color: "#6b6b7d" }}>{r.kind}</div>
                </div>
                <div
                  style={{
                    display: "flex",
                    alignItems: "center",
                    gap: 5,
                    padding: "3px 9px",
                    borderRadius: 7,
                    border: "1px solid rgba(255,255,255,0.16)",
                    background: "rgba(255,255,255,0.06)",
                    fontSize: 13,
                    color: "#a1a1b3",
                    opacity: r.active ? 1 : 0.5,
                  }}
                >
                  <Return size={12} color="#a1a1b3" />
                  {r.hint}
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    ),
    { ...size },
  );
}
