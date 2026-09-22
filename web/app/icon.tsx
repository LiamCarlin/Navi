import { ImageResponse } from "next/og";

export const runtime = "edge";
export const size = { width: 64, height: 64 };
export const contentType = "image/png";

const STAR =
  "M12 1.5c.6 5.4 4.1 9 9.5 10.5-5.4 1.5-8.9 5.1-9.5 10.5-.6-5.4-4.1-9-9.5-10.5C7.9 10.5 11.4 6.9 12 1.5z";

/** Favicon: the ✦ glyph on a dark rounded tile. */
export default function Icon() {
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
          borderRadius: 14,
        }}
      >
        <svg width="42" height="42" viewBox="0 0 24 24">
          <path d={STAR} fill="#8b8cf8" />
        </svg>
      </div>
    ),
    { ...size },
  );
}
