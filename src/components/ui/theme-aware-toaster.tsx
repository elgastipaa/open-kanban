"use client";

import { Toaster } from "sonner";
import { useThemePreference } from "@/components/theme/theme-preference-provider";

export function ThemeAwareToaster() {
  const { state } = useThemePreference();

  return (
    <Toaster
      theme={state.theme}
      position="bottom-right"
      toastOptions={{
        style: {
          background: "var(--color-surface-overlay)",
          border: "1px solid var(--color-border)",
          color: "var(--color-text-primary)",
        },
      }}
      visibleToasts={5}
      richColors
    />
  );
}
