"use client";

import { useEffect, useState } from "react";
import { usePwa } from "@/components/pwa/pwa-provider";
import { getPwaInstallGuidance } from "@/lib/pwa-installation";

export function PwaInstallControl() {
  const { canPromptInstall, installStatus, isStandalone, promptInstall } =
    usePwa();
  const [device, setDevice] = useState<{
    isAppleTouchDevice: boolean;
    userAgent: string;
  } | null>(null);

  useEffect(() => {
    setDevice({
      isAppleTouchDevice: navigator.maxTouchPoints > 1,
      userAgent: navigator.userAgent,
    });
  }, []);

  const guidance = device
    ? getPwaInstallGuidance({
        canPrompt: canPromptInstall,
        isAppleTouchDevice: device.isAppleTouchDevice,
        isStandalone,
        userAgent: device.userAgent,
      })
    : null;

  return (
    <section
      aria-labelledby="pwa-install-title"
      className="mt-8 rounded-xl border border-border bg-surface-base p-5"
    >
      <h2 className="font-display font-semibold text-lg" id="pwa-install-title">
        Abrir OpenKanban como aplicación
      </h2>
      <p className="mt-2 max-w-xl text-sm text-text-secondary leading-6">
        La instalación es opcional. También podés seguir usando OpenKanban en
        este navegador con la misma cuenta y los mismos enlaces privados.
      </p>

      {guidance?.kind === "direct" && (
        <button
          className="mt-4 rounded-lg bg-accent px-4 py-2 font-medium text-accent-foreground text-sm transition hover:opacity-90 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
          onClick={() => void promptInstall()}
          type="button"
        >
          Instalar OpenKanban
        </button>
      )}

      {guidance?.kind === "manual" && (
        <p className="mt-4 text-sm text-text-secondary leading-6">
          {guidance.instructions}
        </p>
      )}

      {guidance?.kind === "web" && (
        <p className="mt-4 text-sm text-text-secondary leading-6">
          {guidance.instructions}
        </p>
      )}

      {guidance?.kind === "installed" && (
        <p className="mt-4 text-sm text-text-secondary leading-6">
          OpenKanban ya está abierta como aplicación.
        </p>
      )}

      {installStatus && (
        <output
          aria-live="polite"
          className="mt-3 block text-sm text-text-secondary"
        >
          {installStatus}
        </output>
      )}
    </section>
  );
}
