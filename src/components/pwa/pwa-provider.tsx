"use client";

import {
  createContext,
  type ReactNode,
  useCallback,
  useContext,
  useEffect,
  useState,
} from "react";

type InstallPromptEvent = Event & {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
};

type PwaContextValue = {
  canPromptInstall: boolean;
  isStandalone: boolean;
  installStatus: string | null;
  promptInstall: () => Promise<void>;
};

const PwaContext = createContext<PwaContextValue | null>(null);

function getIsStandalone() {
  return (
    window.matchMedia("(display-mode: standalone)").matches ||
    (navigator as Navigator & { standalone?: boolean }).standalone === true
  );
}

export function PwaProvider({ children }: { children: ReactNode }) {
  const [installPrompt, setInstallPrompt] = useState<InstallPromptEvent | null>(
    null,
  );
  const [installStatus, setInstallStatus] = useState<string | null>(null);
  const [isStandalone, setIsStandalone] = useState(false);

  useEffect(() => {
    const syncDisplayMode = () => setIsStandalone(getIsStandalone());
    const displayMode = window.matchMedia("(display-mode: standalone)");
    const onBeforeInstallPrompt = (event: Event) => {
      event.preventDefault();
      setInstallPrompt(event as InstallPromptEvent);
    };
    const onAppInstalled = () => {
      setInstallPrompt(null);
      setInstallStatus("OpenKanban se instaló en este dispositivo.");
      syncDisplayMode();
    };

    syncDisplayMode();
    displayMode.addEventListener("change", syncDisplayMode);
    window.addEventListener("beforeinstallprompt", onBeforeInstallPrompt);
    window.addEventListener("appinstalled", onAppInstalled);
    window.addEventListener("pageshow", syncDisplayMode);

    return () => {
      displayMode.removeEventListener("change", syncDisplayMode);
      window.removeEventListener("beforeinstallprompt", onBeforeInstallPrompt);
      window.removeEventListener("appinstalled", onAppInstalled);
      window.removeEventListener("pageshow", syncDisplayMode);
    };
  }, []);

  useEffect(() => {
    if (!("serviceWorker" in navigator)) return;
    void navigator.serviceWorker
      .register("/sw.js", {
        scope: "/",
        updateViaCache: "none",
      })
      .catch(() => undefined);
  }, []);

  const promptInstall = useCallback(async () => {
    const prompt = installPrompt;
    if (!prompt) return;

    setInstallPrompt(null);
    setInstallStatus(null);
    try {
      await prompt.prompt();
      const choice = await prompt.userChoice;
      if (choice.outcome === "accepted") {
        setInstallStatus("El navegador aceptó continuar con la instalación.");
      } else {
        setInstallStatus("La instalación se canceló.");
      }
    } catch {
      setInstallStatus(
        "El navegador no pudo iniciar la instalación. Podés seguir usando la web.",
      );
    }
  }, [installPrompt]);

  return (
    <PwaContext.Provider
      value={{
        canPromptInstall: installPrompt !== null,
        isStandalone,
        installStatus,
        promptInstall,
      }}
    >
      {children}
    </PwaContext.Provider>
  );
}

export function usePwa() {
  const context = useContext(PwaContext);
  if (!context) throw new Error("usePwa debe usarse dentro de PwaProvider");
  return context;
}
