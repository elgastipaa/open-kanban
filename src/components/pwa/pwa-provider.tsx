"use client";

import {
  createContext,
  type ReactNode,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
} from "react";
import { Button } from "@/components/ui/button";
import {
  createPwaUpdateGuardRegistry,
  getPwaUpdateTarget,
  type PwaUpdateGuard,
  registerPwaUpdateGuard,
  requestPwaUpdate,
} from "@/lib/pwa-update-guard";

type InstallPromptEvent = Event & {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
};

type PwaContextValue = {
  canPromptInstall: boolean;
  isStandalone: boolean;
  installStatus: string | null;
  promptInstall: () => Promise<void>;
  registerUpdateGuard: (guard: PwaUpdateGuard) => () => void;
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
  const [updateAvailable, setUpdateAvailable] = useState(false);
  const [updateApplying, setUpdateApplying] = useState(false);
  const [updateStatus, setUpdateStatus] = useState<string | null>(null);
  const [updateGuardRegistry] = useState(createPwaUpdateGuardRegistry);
  const registrationRef = useRef<ServiceWorkerRegistration | null>(null);
  const updateWasWaitingRef = useRef(false);
  const updateActivatedElsewhereRef = useRef(false);
  const updateApplyingRef = useRef(false);

  const registerUpdateGuard = useCallback(
    (guard: PwaUpdateGuard) =>
      registerPwaUpdateGuard(updateGuardRegistry, guard),
    [updateGuardRegistry],
  );

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
    let disposed = false;
    let registration: ServiceWorkerRegistration | null = null;
    let registrationPromise: Promise<ServiceWorkerRegistration | null> | null =
      null;
    let onUpdateFound: (() => void) | null = null;

    const checkWaitingWorker = () => {
      const waiting = registration?.waiting;
      if (!waiting) {
        return;
      }
      if (!navigator.serviceWorker.controller) return;
      updateWasWaitingRef.current = true;
      updateActivatedElsewhereRef.current = false;
      setUpdateAvailable(true);
      setUpdateStatus(null);
    };

    const registerWorker = () => {
      if (registration) return Promise.resolve(registration);
      if (registrationPromise) return registrationPromise;

      registrationPromise = navigator.serviceWorker
        .register("/sw.js", {
          scope: "/",
          updateViaCache: "none",
        })
        .then((nextRegistration) => {
          if (disposed) return null;
          registration = nextRegistration;
          registrationRef.current = nextRegistration;
          checkWaitingWorker();
          onUpdateFound = () => {
            const installing = nextRegistration.installing;
            if (!installing) return;
            const onStateChange = () => {
              if (installing.state !== "installed") return;
              checkWaitingWorker();
              installing.removeEventListener("statechange", onStateChange);
            };
            installing.addEventListener("statechange", onStateChange);
          };
          nextRegistration.addEventListener("updatefound", onUpdateFound);
          return nextRegistration;
        })
        .catch(() => null)
        .finally(() => {
          registrationPromise = null;
        });
      return registrationPromise;
    };

    const checkForUpdate = () => {
      void registerWorker().then((currentRegistration) => {
        if (!currentRegistration || disposed) return;
        void currentRegistration.update().then(checkWaitingWorker).catch(() => {
          // Keep the current application available while the connection returns.
        });
      });
    };

    const reloadAfterActivation = () => {
      if (!updateApplyingRef.current) return;
      updateApplyingRef.current = false;
      updateWasWaitingRef.current = false;
      updateActivatedElsewhereRef.current = false;
      window.location.reload();
    };
    const onControllerChange = () => {
      const updateWasWaiting = updateWasWaitingRef.current;
      checkWaitingWorker();
      if (updateWasWaiting && !registration?.waiting) {
        updateActivatedElsewhereRef.current = true;
        setUpdateAvailable(true);
        setUpdateStatus(null);
      }
      reloadAfterActivation();
    };
    const onVisibilityChange = () => {
      if (!document.hidden) checkForUpdate();
    };

    navigator.serviceWorker.addEventListener(
      "controllerchange",
      onControllerChange,
    );
    window.addEventListener("online", checkForUpdate);
    document.addEventListener("visibilitychange", onVisibilityChange);
    checkForUpdate();

    return () => {
      disposed = true;
      navigator.serviceWorker.removeEventListener(
        "controllerchange",
        onControllerChange,
      );
      window.removeEventListener("online", checkForUpdate);
      document.removeEventListener("visibilitychange", onVisibilityChange);
      if (registration && onUpdateFound) {
        registration.removeEventListener("updatefound", onUpdateFound);
      }
      if (registrationRef.current === registration) {
        registrationRef.current = null;
      }
    };
  }, []);

  const requestUpdate = useCallback(() => {
    const activate = () => {
      if (updateApplyingRef.current) return;
      const waitingWorker = registrationRef.current?.waiting ?? null;
      const updateTarget = getPwaUpdateTarget(
        waitingWorker !== null,
        updateActivatedElsewhereRef.current,
      );
      if (updateTarget === "unavailable") {
        setUpdateStatus(
          "No se pudo preparar la actualización. Volvé a intentarlo cuando tengas conexión.",
        );
        const registration = registrationRef.current;
        if (registration) void registration.update().catch(() => undefined);
        return;
      }

      updateApplyingRef.current = true;
      setUpdateApplying(true);
      setUpdateAvailable(false);
      setUpdateStatus("La actualización se está preparando…");
      if (updateTarget === "active") {
        window.location.reload();
        return;
      }

      try {
        waitingWorker?.postMessage({ type: "ACTIVATE_UPDATE" });
      } catch {
        updateApplyingRef.current = false;
        setUpdateApplying(false);
        setUpdateAvailable(true);
        setUpdateStatus(
          "No se pudo preparar la actualización. Tu edición sigue en esta versión.",
        );
      }
    };

    requestPwaUpdate(updateGuardRegistry, activate);
  }, [updateGuardRegistry]);

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
        registerUpdateGuard,
      }}
    >
      {updateAvailable && (
        <section
          aria-label="Actualización disponible"
          className="flex flex-wrap items-center justify-center gap-3 border-border border-b bg-surface-raised px-4 py-2"
          aria-live="polite"
        >
          <p className="text-sm text-text-primary">
            Hay una actualización disponible.
          </p>
          <Button
            size="sm"
            variant="primary"
            onClick={requestUpdate}
            disabled={updateApplying}
          >
            Recargar para actualizar
          </Button>
        </section>
      )}
      {updateStatus && (
        <p
          aria-live="polite"
          className="sr-only"
        >
          {updateStatus}
        </p>
      )}
      {children}
    </PwaContext.Provider>
  );
}

export function usePwa() {
  const context = useContext(PwaContext);
  if (!context) throw new Error("usePwa debe usarse dentro de PwaProvider");
  return context;
}
