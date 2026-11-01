"use client";

import { IconRefresh } from "@tabler/icons-react";
import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Modal } from "@/components/ui/modal";
import {
  listDeletedTasks,
  restoreTask,
  TaskRecoveryError,
  type TaskRecoveryItem,
} from "@/lib/db/tasks";
import { createClient } from "@/lib/supabase/client";
import {
  formatTaskRecoveryTimestamp,
  getTaskRecoveryListViewState,
  getTaskRecoveryRestoreAction,
  shouldClearTaskRecoveryItems,
  taskRecoveryCauseLabel,
  taskRecoveryLoadErrorMessage,
  taskRecoveryRestoreErrorMessage,
} from "@/lib/task-recovery-state";
import { generateUUID } from "@/lib/utils";

interface RecoveryColumn {
  id: string;
  title: string;
}

interface TaskRecoveryDialogProps {
  open: boolean;
  onClose: () => void;
  onRestored: () => Promise<void>;
  slug: string;
  timeZone: string;
  columns: RecoveryColumn[];
}

export function TaskRecoveryDialog({
  open,
  onClose,
  onRestored,
  slug,
  timeZone,
  columns,
}: TaskRecoveryDialogProps) {
  const [items, setItems] = useState<TaskRecoveryItem[]>([]);
  const [selectedDestinations, setSelectedDestinations] = useState<
    Record<string, string>
  >({});
  const [isLoading, setIsLoading] = useState(false);
  const [restoringTaskId, setRestoringTaskId] = useState<string | null>(null);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const listViewState = getTaskRecoveryListViewState({
    isLoading,
    hasError: Boolean(error),
    itemCount: items.length,
  });

  const refresh = useCallback(async () => {
    setIsLoading(true);
    setError("");
    try {
      setItems(await listDeletedTasks(createClient(), slug));
    } catch (loadError) {
      const reason =
        loadError instanceof TaskRecoveryError ? loadError.reason : null;
      if (shouldClearTaskRecoveryItems(reason)) setItems([]);
      setError(taskRecoveryLoadErrorMessage(reason));
    } finally {
      setIsLoading(false);
    }
  }, [slug]);

  useEffect(() => {
    if (!open) return;
    setItems([]);
    setSelectedDestinations({});
    setError("");
    setMessage("");
    void refresh();
  }, [open, refresh]);

  async function restore(item: TaskRecoveryItem) {
    const selectableColumns = item.original_column_available
      ? columns
      : columns.filter((column) => column.id !== item.original_column_id);
    const action = getTaskRecoveryRestoreAction(
      item,
      selectableColumns.map((column) => column.id),
      selectedDestinations[item.task_id] ?? null,
    );
    if (!action.canRestore) {
      if (action.reason === "expired") {
        setError(
          "El plazo de recuperación venció. Esta tarea ya no se puede recuperar.",
        );
      } else {
        setError("Elige una columna actual para recuperar esta tarea.");
      }
      return;
    }

    setRestoringTaskId(item.task_id);
    setError("");
    setMessage("");
    try {
      const result = await restoreTask(
        createClient(),
        slug,
        generateUUID(),
        item.task_id,
        action.destinationColumnId,
      );
      if (result.status === "confirmed") {
        setMessage("Tarea recuperada en el tablero.");
        try {
          await onRestored();
        } catch {
          setMessage(
            "Tarea recuperada. No se pudo actualizar el tablero; vuelve a cargarlo.",
          );
        }
        await refresh();
      } else if (result.status === "needs_destination") {
        await refresh();
        setError(
          "La columna de origen ya no está disponible. Elige otra columna vigente.",
        );
      } else if (result.status === "expired") {
        await refresh();
        setError(
          "El plazo de recuperación venció. Esta tarea ya no se puede recuperar.",
        );
      } else {
        await refresh();
        setError(
          "La tarea ya no está disponible para recuperar. Actualiza la lista.",
        );
      }
    } catch (restoreError) {
      await refresh();
      setError(
        taskRecoveryRestoreErrorMessage(
          restoreError instanceof TaskRecoveryError
            ? restoreError.reason
            : null,
        ),
      );
    } finally {
      setRestoringTaskId(null);
    }
  }

  return (
    <Modal
      open={open}
      onClose={onClose}
      title="Recuperación de tareas"
      fullScreenMobile
      closeLabel="Cerrar recuperación de tareas"
    >
      <div className="space-y-5 text-text-primary">
        <p className="text-sm text-text-secondary">
          Las tareas se pueden recuperar durante siete días desde su
          eliminación. Abrir esta lista no restaura nada automáticamente.
        </p>

        <div className="flex items-center justify-between gap-3">
          <h3 className="font-semibold text-sm">Tareas eliminadas</h3>
          <Button
            type="button"
            onClick={() => void refresh()}
            disabled={isLoading || restoringTaskId !== null}
            aria-label="Actualizar recuperación"
            title="Actualizar recuperación"
            className="min-h-10"
          >
            <IconRefresh size={16} aria-hidden="true" />
            Actualizar
          </Button>
        </div>

        {listViewState === "loading" ? (
          <output className="text-sm text-text-muted" aria-live="polite">
            Cargando tareas eliminadas…
          </output>
        ) : listViewState === "ready" ? (
          <ul className="divide-y divide-border rounded-lg border border-border">
            {items.map((item) => {
              const selectableColumns = item.original_column_available
                ? columns
                : columns.filter(
                    (column) => column.id !== item.original_column_id,
                  );
              const selectedDestination =
                selectedDestinations[item.task_id] ?? null;
              const action = getTaskRecoveryRestoreAction(
                item,
                selectableColumns.map((column) => column.id),
                selectedDestination,
              );
              const requiresDestination =
                item.can_restore && !item.original_column_available;
              const isRestoring = restoringTaskId === item.task_id;
              const destinationLabelId = `task-recovery-destination-${item.task_id}`;

              return (
                <li
                  key={item.task_id}
                  className="flex flex-col gap-4 p-4 sm:flex-row sm:items-center sm:justify-between"
                >
                  <div className="min-w-0 space-y-1">
                    <p className="font-medium text-sm">{item.title}</p>
                    <p className="text-text-muted text-xs">Tipo: Tarea</p>
                    <p className="text-text-muted text-xs">
                      {taskRecoveryCauseLabel(item.cause)}
                    </p>
                    <p className="text-text-muted text-xs">
                      Eliminada:{" "}
                      {formatTaskRecoveryTimestamp(item.deleted_at, timeZone)}
                    </p>
                    <p className="text-text-muted text-xs">
                      Vence:{" "}
                      {formatTaskRecoveryTimestamp(item.expires_at, timeZone)}
                    </p>
                    {!item.can_restore ? (
                      <p className="text-priority-urgent text-xs">
                        El plazo venció; no se puede recuperar.
                      </p>
                    ) : requiresDestination ? (
                      selectableColumns.length > 0 ? (
                        <div className="space-y-1 pt-2">
                          <label
                            id={destinationLabelId}
                            htmlFor={destinationLabelId}
                            className="block text-text-secondary text-xs"
                          >
                            Columna de destino
                          </label>
                          <select
                            id={destinationLabelId}
                            value={selectedDestination ?? ""}
                            onChange={(event) =>
                              setSelectedDestinations((current) => ({
                                ...current,
                                [item.task_id]: event.target.value,
                              }))
                            }
                            disabled={restoringTaskId !== null}
                            className="min-h-10 w-full rounded-md border border-border bg-surface-base px-3 text-sm focus:border-accent focus:outline-none sm:min-w-64"
                          >
                            <option value="">Elige una columna</option>
                            {selectableColumns.map((column) => (
                              <option key={column.id} value={column.id}>
                                {column.title}
                              </option>
                            ))}
                          </select>
                        </div>
                      ) : (
                        <p className="pt-2 text-text-muted text-xs">
                          Crea una columna vigente antes de recuperar esta
                          tarea.
                        </p>
                      )
                    ) : null}
                  </div>

                  {item.can_restore ? (
                    <Button
                      type="button"
                      variant="primary"
                      onClick={() => void restore(item)}
                      disabled={
                        restoringTaskId !== null ||
                        !action.canRestore ||
                        (requiresDestination && !selectedDestination)
                      }
                      aria-label={`Recuperar tarea: ${item.title}`}
                      className="min-h-11 shrink-0"
                    >
                      {isRestoring ? "Recuperando…" : "Recuperar tarea"}
                    </Button>
                  ) : (
                    <span className="shrink-0 text-sm text-text-muted">
                      No recuperable
                    </span>
                  )}
                </li>
              );
            })}
          </ul>
        ) : listViewState === "empty" ? (
          <p className="rounded-lg border border-border border-dashed p-4 text-sm text-text-muted">
            No hay tareas eliminadas para recuperar en este tablero.
          </p>
        ) : null}

        {error ? (
          <p
            className="rounded-lg border border-red-400/30 bg-red-400/5 p-3 text-red-200 text-sm"
            role="alert"
          >
            {error}
          </p>
        ) : null}
        {message ? (
          <output className="text-sm text-text-secondary" aria-live="polite">
            {message}
          </output>
        ) : null}
      </div>
    </Modal>
  );
}
