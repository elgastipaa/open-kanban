import { ImageResponse } from "next/og";

export const size = { width: 180, height: 180 };
export const contentType = "image/png";

export default function AppleIcon() {
  return new ImageResponse(
    <div
      style={{
        alignItems: "center",
        backgroundColor: "#111514",
        display: "flex",
        height: "100%",
        justifyContent: "center",
        width: "100%",
      }}
    >
      <div
        style={{
          display: "flex",
          gap: 12,
          height: 140,
          width: 140,
        }}
      >
        <div
          style={{
            backgroundColor: "#dfff00",
            borderRadius: 16,
            flex: 1,
          }}
        />
        <div
          style={{
            backgroundColor: "#dfff00",
            borderRadius: 16,
            flex: 1,
          }}
        />
        <div
          style={{
            backgroundColor: "#dfff00",
            borderRadius: 16,
            flex: 1,
          }}
        />
      </div>
    </div>,
    size,
  );
}
