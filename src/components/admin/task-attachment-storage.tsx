"use client";

import { IconRefresh } from "@tabler/icons-react";
import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { generateUUID } from "@/lib/utils";

interface StorageSummary {
  limit_bytes: number;
  used_bytes: number;
  active_bytes: number;
  recoverable_bytes: number;
  reserved_bytes: number;
  pending_bytes: number;
  active_count: number;
  recoverable_count: number;
  reserved_count: number;
  pending_count: number;
}

interface CleanupCandidate {
  attachment_id: string;
  board_reference: string;
  task_reference: string;
  owner_reference: string | null;
  uploaded_by_reference: string;
  size_bytes: number;
  created_at: string;
  state: string;
  deletion_cause: string | null;
  task_state: string;
  expires_at: string | null;
}

type AdminAction = {
  item: CleanupCandidate;
  kind: "clean" | "restore";
  operationId: string;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isSafeCount(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value);
}

function parseSummary(value: unknown): StorageSummary | null {
  if (!isRecord(value) || value.status !== "ok") return null;
  if (
    !isSafeCount(value.limit_bytes) ||
    !isSafeCount(value.used_bytes) ||
    !isSafeCount(value.active_bytes) ||
    !isSafeCount(value.recoverable_bytes) ||
    !isSafeCount(value.reserved_bytes) ||
    !isSafeCount(value.pending_bytes) ||
    !isSafeCount(value.active_count) ||
    !isSafeCount(value.recoverable_count) ||
    !isSafeCount(value.reserved_count) ||
    !isSafeCount(value.pending_count)
  ) {
    return null;
  }
  return {
    limit_bytes: value.limit_bytes,
    used_bytes: value.used_bytes,
    active_bytes: value.active_bytes,
    recoverable_bytes: value.recoverable_bytes,
    reserved_bytes: value.reserved_bytes,
    pending_bytes: value.pending_bytes,
    active_count: value.active_count,
    recoverable_count: value.recoverable_count,
    reserved_count: value.reserved_count,
    pending_count: value.pending_count,
  };
}

function parseCandidate(value: unknown): CleanupCandidate | null {
  if (
    !isRecord(value) ||
    typeof value.attachment_id !== "string" ||
    typeof value.board_reference !== "string" ||
    typeof value.task_reference !== "string" ||
    (value.owner_reference !== null &&
      typeof value.owner_reference !== "string") ||
    typeof value.uploaded_by_reference !== "string" ||
    typeof value.size_bytes !== "number" ||
    typeof value.created_at !== "string" ||
    typeof value.state !== "string" ||
    (value.deletion_cause !== null &&
      typeof value.deletion_cause !== "string") ||
    typeof value.task_state !== "string" ||
    (value.expires_at !== null && typeof value.expires_at !== "string")
  ) {
    return null;
  }
  return value as unknown as CleanupCandidate;
}

function formatDecimalMegabytes(bytes: number): string {
  return `${(bytes / 1_000_000).toLocaleString("es-AR", {
    maximumFractionDigits: 1,
  })} MB`;
}

function formatTimestamp(value: string | null): string {
  if (!value) return "—";
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return "Fecha desconocida";
  return new Intl.DateTimeFormat("es-AR", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

function candidateState(item: CleanupCandidate): string {
  const attachment = item.state === "active" ? "Activo" : "En recuperación";
  const task =
    item.task_state === "active"
      ? "tarea activa"
      : item.task_state === "recoverable"
        ? "tarea eliminada"
        : item.task_state === "board_recoverable"
          ? "tablero en recuperación"
          : item.task_state === "purged"
            ? "tarea purgada"
            : "tarea no disponible";
  return `${attachment} · ${task}`;
}

export function AdminTaskAttachmentStorage() {
  const [summary, setSummary] = useState<StorageSummary | null>(null);
  const [items, setItems] = useState<CleanupCandidate[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [error, setError] = useState("");
  const [action, setAction] = useState<AdminAction | null>(null);
  const [isWorking, setIsWorking] = useState(false);

  const refresh = useCallback(async (signal?: AbortSignal) => {
    const response = await fetch("/api/admin/task-attachments", {
      cache: "no-store",
      signal,
    });
    const payload: unknown = await response.json().catch(() => null);
    if (!response.ok || !isRecord(payload) || payload.status !== "ok") {
      throw new Error("No se pudo consultar el almacenamiento.");
    }
    const nextSummary = parseSummary(payload.summary);
    const nextItems = Array.isArray(payload.items)
      ? payload.items.map(parseCandidate)
      : null;
    if (!nextSummary || !nextItems || nextItems.some((item) => item === null)) {
      throw new Error("No se pudo consultar el almacenamiento.");
    }
    setSummary(nextSummary);
    setItems(nextItems as CleanupCandidate[]);
    setError("");
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    void refresh(controller.signal)
      .catch(() => {
        if (!controller.signal.aborted) {
          setError("No se pudo consultar el almacenamiento.");
        }
      })
      .finally(() => {
        if (!controller.signal.aborted) setIsLoading(false);
      });
    return () => controller.abort();
  }, [refresh]);

  async function reload() {
    setIsRefreshing(true);
    try {
      await refresh();
    } catch {
      setError("No se pudo consultar el almacenamiento.");
    } finally {
      setIsRefreshing(false);
    }
  }

  function startAction(item: CleanupCandidate, kind: AdminAction["kind"]) {
    setAction({ item, kind, operationId: generateUUID() });
  }

  async function confirmAction() {
    if (!action) return;
    setIsWorking(true);
    setError("");
    try {
      const response = await fetch(
        `/api/admin/task-attachments/${encodeURIComponent(action.item.attachment_id)}`,
        {
          method: action.kind === "clean" ? "DELETE" : "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ operation_id: action.operationId }),
        },
      );
      const result: unknown = await response.json().catch(() => null);
      if (!response.ok || !isRecord(result) || result.status !== "confirmed") {
        throw new Error(
          "La selección ya no está disponible. Actualiza el listado.",
        );
      }
      setAction(null);
      await refresh();
    } catch (error) {
      setError(
        error instanceof Error
          ? error.message
          : "No se pudo actualizar el archivo.",
      );
    } finally {
      setIsWorking(false);
    }
  }

  return (
    <section
      aria-labelledby="admin-attachment-storage-heading"
      className="mt-10 border-border border-t pt-8"
    >
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2
            id="admin-attachment-storage-heading"
            className="font-semibold text-text-primary text-xl"
          >
            Capacidad y limpieza de adjuntos
          </h2>
          <p className="mt-2 max-w-3xl text-sm text-text-secondary leading-6">
            Se muestran referencias, tamaño, fecha, estado y propietario. Esta
            vista no permite leer nombres ni descargar contenido. La limpieza
            conserva la cuota durante siete días y avisa al propietario actual.
          </p>
        </div>
        <Button
          size="sm"
          onClick={() => void reload()}
          disabled={isRefreshing || isLoading}
          aria-label="Actualizar capacidad y adjuntos"
        >
          <IconRefresh
            size={15}
            aria-hidden="true"
            className={isRefreshing ? "animate-spin" : ""}
          />
          Actualizar
        </Button>
      </div>

      {error ? (
        <p
          role="alert"
          className="mt-4 rounded-lg border border-priority-urgent/30 bg-priority-urgent/10 p-3 text-priority-urgent text-sm"
        >
          {error}
        </p>
      ) : null}
      {isLoading ? (
        <output className="mt-5 text-sm text-text-muted">
          Consultando capacidad y referencias…
        </output>
      ) : summary ? (
        <>
          <dl className="mt-5 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <div className="rounded-lg border border-border bg-surface-raised p-4">
              <dt className="text-text-muted text-xs">Uso global</dt>
              <dd className="mt-1 font-semibold text-text-primary">
                {formatDecimalMegabytes(summary.used_bytes)} /{" "}
                {formatDecimalMegabytes(summary.limit_bytes)}
              </dd>
            </div>
            <div className="rounded-lg border border-border bg-surface-raised p-4">
              <dt className="text-text-muted text-xs">Activos</dt>
              <dd className="mt-1 font-semibold text-text-primary">
                {formatDecimalMegabytes(summary.active_bytes)} ·{" "}
                {summary.active_count}
              </dd>
            </div>
            <div className="rounded-lg border border-border bg-surface-raised p-4">
              <dt className="text-text-muted text-xs">En recuperación</dt>
              <dd className="mt-1 font-semibold text-text-primary">
                {formatDecimalMegabytes(summary.recoverable_bytes)} ·{" "}
                {summary.recoverable_count}
              </dd>
            </div>
            <div className="rounded-lg border border-border bg-surface-raised p-4">
              <dt className="text-text-muted text-xs">
                Reservas y limpieza pendiente
              </dt>
              <dd className="mt-1 font-semibold text-text-primary">
                {formatDecimalMegabytes(
                  summary.reserved_bytes + summary.pending_bytes,
                )}{" "}
                · {summary.reserved_count + summary.pending_count}
              </dd>
            </div>
          </dl>

          {items.length === 0 ? (
            <p className="mt-5 rounded-lg border border-border p-4 text-sm text-text-muted">
              No hay adjuntos que requieran limpieza administrativa.
            </p>
          ) : (
            <div className="mt-5 overflow-x-auto rounded-lg border border-border">
              <table className="w-full min-w-[760px] text-left text-sm">
                <caption className="sr-only">
                  Referencias privadas para capacidad y limpieza de adjuntos
                </caption>
                <thead className="bg-surface-raised text-text-muted text-xs">
                  <tr>
                    <th scope="col" className="px-3 py-3">
                      Referencia
                    </th>
                    <th scope="col" className="px-3 py-3">
                      Tablero / tarea
                    </th>
                    <th scope="col" className="px-3 py-3">
                      Propietario
                    </th>
                    <th scope="col" className="px-3 py-3">
                      Tamaño / fecha
                    </th>
                    <th scope="col" className="px-3 py-3">
                      Estado
                    </th>
                    <th scope="col" className="px-3 py-3">
                      Acción
                    </th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-border">
                  {items.map((item) => (
                    <tr key={item.attachment_id}>
                      <th
                        scope="row"
                        className="px-3 py-3 align-top font-normal"
                      >
                        <code className="break-all text-xs">
                          {item.attachment_id}
                        </code>
                      </th>
                      <td className="px-3 py-3 align-top text-xs">
                        <code className="block break-all">
                          {item.board_reference}
                        </code>
                        <code className="mt-1 block break-all">
                          {item.task_reference}
                        </code>
                      </td>
                      <td className="px-3 py-3 align-top text-xs">
                        {item.owner_reference ? (
                          <code className="break-all">
                            {item.owner_reference}
                          </code>
                        ) : (
                          "No disponible"
                        )}
                      </td>
                      <td className="px-3 py-3 align-top text-xs">
                        <span className="block">
                          {item.size_bytes.toLocaleString("es-AR")} bytes
                        </span>
                        <time
                          dateTime={item.created_at}
                          className="mt-1 block text-text-muted"
                        >
                          {formatTimestamp(item.created_at)}
                        </time>
                      </td>
                      <td className="px-3 py-3 align-top text-xs">
                        <span>{candidateState(item)}</span>
                        {item.expires_at ? (
                          <time
                            dateTime={item.expires_at}
                            className="mt-1 block text-text-muted"
                          >
                            Vence {formatTimestamp(item.expires_at)}
                          </time>
                        ) : null}
                      </td>
                      <td className="px-3 py-3 align-top">
                        {item.state === "active" ? (
                          <Button
                            size="sm"
                            variant="danger"
                            onClick={() => startAction(item, "clean")}
                          >
                            Limpiar
                          </Button>
                        ) : item.deletion_cause === "admin_cleanup" ? (
                          <Button
                            size="sm"
                            onClick={() => startAction(item, "restore")}
                          >
                            Recuperar
                          </Button>
                        ) : (
                          <span className="text-text-muted text-xs">
                            Sin acción
                          </span>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      ) : null}

      <ConfirmDialog
        open={action !== null}
        onClose={() => {
          if (!isWorking) setAction(null);
        }}
        onConfirm={() => void confirmAction()}
        title={
          action?.kind === "clean"
            ? "Confirmar limpieza administrativa"
            : "Recuperar archivo limpiado"
        }
        description={
          action?.kind === "clean"
            ? `Se enviará a recuperación el adjunto de referencia ${action.item.attachment_id}. El propietario actual recibirá una novedad. La cuota seguirá ocupada hasta que la purga confirme que el objeto ya no existe en Storage.`
            : `Se reactivará el adjunto de referencia ${action?.item.attachment_id ?? ""} si la ventana de recuperación sigue vigente. La restauración requiere una cuenta administradora habilitada.`
        }
        confirmLabel={
          action?.kind === "clean"
            ? "Enviar a recuperación"
            : "Recuperar archivo"
        }
        cancelLabel="Cancelar"
        loading={isWorking}
      />
    </section>
  );
}
