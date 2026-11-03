"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import {
  parseTaskAttachmentCapacityNotices,
  type TaskAttachmentCapacityNotice,
  taskAttachmentCapacityNoticeMessage,
} from "@/lib/task-attachment-capacity-notice";

export function TaskAttachmentCapacityNotices() {
  const [items, setItems] = useState<TaskAttachmentCapacityNotice[]>([]);
  const [loadError, setLoadError] = useState(false);
  const [savingThreshold, setSavingThreshold] = useState<number | null>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    const controller = new AbortController();
    void fetch("/api/task-attachment-capacity-notices", {
      cache: "no-store",
      signal: controller.signal,
    })
      .then(async (response) => {
        const payload: unknown = await response.json().catch(() => null);
        const notices = parseTaskAttachmentCapacityNotices(payload);
        if (!response.ok || !notices) throw new Error("unavailable");
        setItems(notices);
      })
      .catch(() => {
        if (!controller.signal.aborted) setLoadError(true);
      });
    return () => controller.abort();
  }, []);

  async function markRead(thresholdBytes: number) {
    if (savingThreshold !== null) return;
    setSavingThreshold(thresholdBytes);
    setError("");
    try {
      const response = await fetch("/api/task-attachment-capacity-notices", {
        method: "POST",
        cache: "no-store",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ threshold_bytes: thresholdBytes }),
      });
      const payload: unknown = await response.json().catch(() => null);
      if (
        !response.ok ||
        typeof payload !== "object" ||
        payload === null ||
        !("status" in payload) ||
        payload.status !== "confirmed"
      ) {
        throw new Error("unavailable");
      }
      setItems((current) =>
        current.filter((item) => item.threshold_bytes !== thresholdBytes),
      );
    } catch {
      setError("No se pudo marcar el aviso como leído. Inténtalo de nuevo.");
    } finally {
      setSavingThreshold(null);
    }
  }

  if (!loadError && items.length === 0 && !error) return null;

  return (
    <section
      aria-label="Avisos de capacidad de archivos"
      className="mt-6 space-y-3"
      aria-live="polite"
    >
      {loadError ? (
        <p
          className="rounded-lg border border-priority-urgent/30 bg-priority-urgent/10 p-4 text-priority-urgent text-sm"
          role="alert"
        >
          No se pudieron consultar los avisos de capacidad.
        </p>
      ) : null}
      {items.map((item) => (
        <article
          key={item.threshold_bytes}
          className="flex flex-wrap items-center justify-between gap-4 rounded-lg border border-priority-medium/30 bg-priority-medium/10 p-4"
        >
          <div className="min-w-0 flex-1">
            <h2 className="font-semibold text-text-primary">
              Aviso de almacenamiento de archivos
            </h2>
            <p className="mt-1 text-sm text-text-secondary">
              {taskAttachmentCapacityNoticeMessage(item)}
            </p>
            <p className="mt-1 text-text-muted text-xs">
              Aviso emitido{" "}
              {new Intl.DateTimeFormat("es-AR", {
                dateStyle: "medium",
                timeStyle: "short",
              }).format(new Date(item.last_notified_at))}
            </p>
            <Link
              href="/"
              className="mt-2 inline-flex min-h-10 items-center rounded-md text-accent underline underline-offset-2"
            >
              Revisar tus tableros
            </Link>
          </div>
          <Button
            size="md"
            className="min-h-10"
            onClick={() => void markRead(item.threshold_bytes)}
            disabled={savingThreshold !== null}
          >
            {savingThreshold === item.threshold_bytes
              ? "Guardando…"
              : "Marcar como leído"}
          </Button>
        </article>
      ))}
      {error ? (
        <p className="text-priority-urgent text-sm" role="alert">
          {error}
        </p>
      ) : null}
    </section>
  );
}
