"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { Modal } from "@/components/ui/modal";
import {
  type BoardTaskAttachmentCursor,
  type BoardTaskAttachmentStoragePage,
  type CompletedTaskAttachmentCleanupPreview,
  parseBoardTaskAttachmentStoragePage,
  parseCompletedTaskAttachmentCleanupPreview,
} from "@/lib/task-attachment-board-cleanup";
import { generateUUID } from "@/lib/utils";

interface TaskAttachmentStorageProps {
  slug: string;
  open: boolean;
  onClose: () => void;
}

interface PendingCleanup {
  item: CompletedTaskAttachmentCleanupPreview;
  operationId: string;
}

function formatBytes(value: number): string {
  return `${value.toLocaleString("es-AR")} bytes`;
}

function formatTimestamp(value: string | null): string {
  if (!value) return "";
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return "Fecha desconocida";
  return new Intl.DateTimeFormat("es-AR", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

function storageUrl(slug: string, cursor: BoardTaskAttachmentCursor | null) {
  const url = new URL(
    `/api/boards/${encodeURIComponent(slug)}/task-attachments`,
    window.location.origin,
  );
  if (cursor) {
    url.searchParams.set("cursor_created_at", cursor.createdAt);
    url.searchParams.set("cursor_attachment_id", cursor.attachmentId);
  }
  return url.toString();
}

export function TaskAttachmentStorage({
  slug,
  open,
  onClose,
}: TaskAttachmentStorageProps) {
  const [page, setPage] = useState<BoardTaskAttachmentStoragePage | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [onlyCompletedTasks, setOnlyCompletedTasks] = useState(false);
  const [previewingId, setPreviewingId] = useState<string | null>(null);
  const [pendingCleanup, setPendingCleanup] = useState<PendingCleanup | null>(
    null,
  );
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [isCleaning, setIsCleaning] = useState(false);
  const [cleanupError, setCleanupError] = useState("");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const operationIds = useRef(new Map<string, string>());

  const load = useCallback(
    async (cursor: BoardTaskAttachmentCursor | null = null) => {
      const response = await fetch(storageUrl(slug, cursor), {
        cache: "no-store",
      });
      const payload: unknown = await response.json().catch(() => null);
      const nextPage = parseBoardTaskAttachmentStoragePage(payload);
      if (!response.ok || !nextPage) {
        throw new Error("No se pudo consultar el almacenamiento del tablero.");
      }
      setPage((current) => {
        if (!cursor || !current) return nextPage;
        const existing = new Set(
          current.items.map((item) => item.attachment_id),
        );
        return {
          ...nextPage,
          items: [
            ...current.items,
            ...nextPage.items.filter(
              (item) => !existing.has(item.attachment_id),
            ),
          ],
        };
      });
      setError("");
    },
    [slug],
  );

  useEffect(() => {
    if (!open) return;
    setIsLoading(true);
    setError("");
    void load()
      .catch(() =>
        setError("No se pudo consultar el almacenamiento del tablero."),
      )
      .finally(() => setIsLoading(false));
  }, [load, open]);

  async function refresh() {
    setIsLoading(true);
    try {
      await load();
      setNotice("Lista actualizada.");
    } catch {
      setError("No se pudo actualizar el almacenamiento del tablero.");
    } finally {
      setIsLoading(false);
    }
  }

  async function loadMore() {
    if (!page?.next_cursor || isLoadingMore) return;
    setIsLoadingMore(true);
    try {
      await load(page.next_cursor);
    } catch {
      setError("No se pudieron cargar más archivos.");
    } finally {
      setIsLoadingMore(false);
    }
  }

  async function previewCleanup(attachmentId: string) {
    setPreviewingId(attachmentId);
    setCleanupError("");
    setNotice("");
    try {
      const response = await fetch(
        `/api/boards/${encodeURIComponent(slug)}/task-attachments`,
        {
          method: "POST",
          cache: "no-store",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            action: "preview",
            attachment_id: attachmentId,
          }),
        },
      );
      const payload: unknown = await response.json().catch(() => null);
      const preview = parseCompletedTaskAttachmentCleanupPreview(payload);
      if (!response.ok || !preview) {
        throw new Error("El archivo o la tarea cambió. Actualiza la lista.");
      }
      const operationId =
        operationIds.current.get(attachmentId) ?? generateUUID();
      operationIds.current.set(attachmentId, operationId);
      setPendingCleanup({ item: preview.item, operationId });
      setConfirmOpen(true);
    } catch (cause) {
      const message =
        cause instanceof Error
          ? cause.message
          : "No se pudo preparar la limpieza. Actualiza la lista.";
      await load().catch(() => undefined);
      setError(message);
    } finally {
      setPreviewingId(null);
    }
  }

  async function confirmCleanup() {
    if (!pendingCleanup || isCleaning) return;
    setIsCleaning(true);
    setCleanupError("");
    setError("");
    try {
      const response = await fetch(
        `/api/boards/${encodeURIComponent(slug)}/task-attachments`,
        {
          method: "POST",
          cache: "no-store",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            action: "cleanup",
            attachment_id: pendingCleanup.item.attachment_id,
            operation_id: pendingCleanup.operationId,
          }),
        },
      );
      const result: unknown = await response.json().catch(() => null);
      if (
        response.ok &&
        typeof result === "object" &&
        result !== null &&
        "status" in result &&
        result.status === "confirmed"
      ) {
        operationIds.current.delete(pendingCleanup.item.attachment_id);
        setPendingCleanup(null);
        setConfirmOpen(false);
        setNotice(
          "El archivo pasó a recuperación. La cuota seguirá ocupada hasta que la purga confirme su eliminación.",
        );
        await load().catch(() =>
          setError("Limpieza confirmada, pero no se pudo actualizar la lista."),
        );
        return;
      }
      if (response.status === 409) {
        operationIds.current.delete(pendingCleanup.item.attachment_id);
        setPendingCleanup(null);
        setConfirmOpen(false);
        await load().catch(() => undefined);
        setError("El archivo o la tarea cambió. Actualiza la lista.");
        return;
      }
      setCleanupError(
        "No se pudo confirmar la operación. Puedes reintentar; se conservará el mismo identificador para reconciliar el resultado.",
      );
      await load().catch(() => undefined);
    } catch {
      setCleanupError(
        "Se perdió la respuesta. Reintenta con el mismo identificador para reconciliar el resultado.",
      );
      await load().catch(() => undefined);
    } finally {
      setIsCleaning(false);
    }
  }

  const visibleItems = page?.items.filter(
    (item) => !onlyCompletedTasks || item.task_completed,
  );
  const usedPercent = page
    ? Math.min(
        100,
        Math.round(
          (page.global_capacity.used_bytes / page.global_capacity.limit_bytes) *
            100,
        ),
      )
    : 0;

  return (
    <>
      <Modal
        open={open}
        onClose={onClose}
        title="Archivos y almacenamiento"
        fullScreenMobile
      >
        <div className="space-y-5 text-sm text-text-secondary">
          <p className="leading-6">
            Este tablero usa el almacenamiento global compartido de OpenKanban;
            no tiene una cuota independiente. Los archivos recuperables,
            reservas y limpiezas pendientes siguen ocupando espacio hasta que la
            purga confirme la eliminación.
          </p>

          {page ? (
            <section
              aria-label="Uso del almacenamiento"
              className="grid gap-3 rounded-lg border border-border bg-surface-raised p-4 sm:grid-cols-2"
            >
              <div>
                <h3 className="font-semibold text-text-primary">
                  Este tablero
                </h3>
                <p className="mt-2">
                  Activos: {formatBytes(page.board_usage.active_bytes)} ·{" "}
                  {page.board_usage.active_count} archivos
                </p>
                <p>
                  En recuperación:{" "}
                  {formatBytes(page.board_usage.recoverable_bytes)}
                  {page.board_usage.recoverable_count > 0
                    ? ` · ${page.board_usage.recoverable_count} archivos`
                    : ""}
                </p>
                <p>
                  Reservados: {formatBytes(page.board_usage.reserved_bytes)} ·
                  pendientes de purga:{" "}
                  {formatBytes(page.board_usage.pending_bytes)}
                </p>
              </div>
              <div>
                <h3 className="font-semibold text-text-primary">
                  Capacidad global
                </h3>
                <p className="mt-2">
                  {formatBytes(page.global_capacity.used_bytes)} de{" "}
                  {formatBytes(page.global_capacity.limit_bytes)} ({usedPercent}{" "}
                  %)
                </p>
                <p>
                  Aviso al alcanzar{" "}
                  {formatBytes(page.global_capacity.warning_threshold_bytes)}{" "}
                  (80 %). Los rechazos de nuevas cargas se informan en el
                  momento.
                </p>
              </div>
            </section>
          ) : null}

          <div className="flex flex-wrap items-center justify-between gap-3">
            <label className="inline-flex min-h-10 items-center gap-2 text-text-primary">
              <input
                type="checkbox"
                checked={onlyCompletedTasks}
                onChange={(event) =>
                  setOnlyCompletedTasks(event.target.checked)
                }
                className="h-4 w-4 accent-accent"
              />
              Solo tareas completadas
            </label>
            <Button onClick={() => void refresh()} disabled={isLoading}>
              {isLoading ? "Actualizando…" : "Actualizar"}
            </Button>
          </div>

          {isLoading && !page ? (
            <output className="block" aria-live="polite">
              Cargando archivos…
            </output>
          ) : null}
          {error ? (
            <p
              className="rounded-md bg-priority-urgent/10 p-3 text-priority-urgent"
              role="alert"
            >
              {error}
            </p>
          ) : null}
          {notice ? (
            <output className="block text-text-secondary" aria-live="polite">
              {notice}
            </output>
          ) : null}
          {page && visibleItems?.length === 0 ? (
            <p className="rounded-md border border-border p-4">
              {onlyCompletedTasks
                ? page.has_more
                  ? "No hay archivos de tareas completadas en esta página. Carga más para continuar la revisión."
                  : "No hay archivos disponibles en tareas completadas."
                : "Este tablero todavía no tiene archivos activos ni recuperables."}
            </p>
          ) : null}
          {visibleItems && visibleItems.length > 0 ? (
            <ul className="divide-y divide-border rounded-md border border-border">
              {visibleItems.map((item) => (
                <li
                  key={item.attachment_id}
                  className="flex flex-wrap items-center justify-between gap-3 p-4"
                >
                  <div className="min-w-0">
                    <p className="break-words font-medium text-text-primary">
                      {item.file_name}
                    </p>
                    <p className="mt-1 break-words text-text-secondary">
                      Tarea: {item.task_title}
                    </p>
                    <p className="mt-1 text-text-muted text-xs">
                      {formatBytes(item.size_bytes)} ·{" "}
                      {item.task_completed
                        ? "Tarea completada"
                        : "Tarea abierta"}
                      {item.state === "recoverable"
                        ? ` · Recuperable hasta ${formatTimestamp(item.expires_at)}`
                        : ` · Subido ${formatTimestamp(item.created_at)}`}
                    </p>
                  </div>
                  {item.state === "active" && item.task_completed ? (
                    <Button
                      size="md"
                      className="min-h-10"
                      onClick={() => void previewCleanup(item.attachment_id)}
                      disabled={previewingId !== null || isCleaning}
                      aria-busy={previewingId === item.attachment_id}
                    >
                      {previewingId === item.attachment_id
                        ? "Preparando vista…"
                        : "Previsualizar limpieza"}
                    </Button>
                  ) : null}
                </li>
              ))}
            </ul>
          ) : null}
          {page?.has_more ? (
            <div className="flex justify-center">
              <Button onClick={() => void loadMore()} disabled={isLoadingMore}>
                {isLoadingMore ? "Cargando…" : "Cargar más archivos"}
              </Button>
            </div>
          ) : null}
        </div>
      </Modal>
      <ConfirmDialog
        open={confirmOpen && pendingCleanup !== null}
        onClose={() => {
          if (!isCleaning) {
            setConfirmOpen(false);
            setCleanupError("");
          }
        }}
        onConfirm={() => void confirmCleanup()}
        title="Confirmar limpieza del archivo"
        description={
          pendingCleanup
            ? `Se enviará «${pendingCleanup.item.file_name}» (${formatBytes(pendingCleanup.item.size_bytes)}, subido ${formatTimestamp(pendingCleanup.item.created_at)}) de la tarea «${pendingCleanup.item.task_title}» a recuperación por siete días. Esta acción no libera cuota: el espacio se libera solo cuando la purga confirma la eliminación.${cleanupError ? ` ${cleanupError}` : ""}`
            : ""
        }
        confirmLabel={isCleaning ? "Enviando…" : "Enviar a recuperación"}
        cancelLabel="Cancelar"
        loading={isCleaning}
      />
    </>
  );
}
