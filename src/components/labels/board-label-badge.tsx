import type { CSSProperties } from "react";
import type { BoardLabel, BoardLabelColor } from "@/lib/types";

const palette: Record<
  BoardLabelColor,
  { background: string; foreground: string; border: string }
> = {
  red: { background: "#fee2e2", foreground: "#7f1d1d", border: "#fca5a5" },
  orange: { background: "#ffedd5", foreground: "#7c2d12", border: "#fdba74" },
  yellow: { background: "#fef9c3", foreground: "#713f12", border: "#fde047" },
  green: { background: "#dcfce7", foreground: "#14532d", border: "#86efac" },
  teal: { background: "#ccfbf1", foreground: "#134e4a", border: "#5eead4" },
  blue: { background: "#dbeafe", foreground: "#1e3a8a", border: "#93c5fd" },
  purple: { background: "#ede9fe", foreground: "#4c1d95", border: "#c4b5fd" },
  pink: { background: "#fce7f3", foreground: "#831843", border: "#f9a8d4" },
  gray: { background: "#f1f5f9", foreground: "#334155", border: "#cbd5e1" },
};

export function boardLabelStyle(color: BoardLabelColor): CSSProperties {
  const swatch = palette[color];
  return {
    backgroundColor: swatch.background,
    borderColor: swatch.border,
    color: swatch.foreground,
  };
}

export function BoardLabelBadge({
  label,
  className = "",
}: {
  label: BoardLabel;
  className?: string;
}) {
  return (
    <span
      className={`inline-flex max-w-full items-center rounded-full border px-2 py-0.5 font-medium text-[11px] leading-tight ${className}`}
      style={boardLabelStyle(label.color)}
      title={label.name}
    >
      <span className="truncate">{label.name}</span>
    </span>
  );
}
