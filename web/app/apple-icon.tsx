import { ImageResponse } from "next/og";

export const runtime = "edge";
export const size = { width: 180, height: 180 };
export const contentType = "image/png";

const STAR =
  "M12 1.5c.6 5.4 4.1 9 9.5 10.5-5.4 1.5-8.9 5.1-9.5 10.5-.6-5.4-4.1-9-9.5-10.5C7.9 10.5 11.4 6.9 12 1.5z";

export default function AppleIcon() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          background: "#0d0d14",
          backgroundImage: "radial-gradient(70% 70% at 50% 20%, rgba(139,140,248,0.35), transparent 70%)",
        }}
      >
        <svg width="112" height="112" viewBox="0 0 24 24">
          <path d={STAR} fill="#8b8cf8" />
        </svg>
      </div>
    ),
    { ...size },
  );
}
