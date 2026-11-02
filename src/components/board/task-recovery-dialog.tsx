"use client";

import { IconRefresh } from "@tabler/icons-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Modal } from "@/components/ui/modal";
import {
  ColumnRecoveryError,
  type DeletedColumnRecoveryItem,
  listDeletedColumns,
  restoreColumn,
} from "@/lib/db/columns";
import {
  type DeletedRepetitionSeriesItem,
  listDeletedRepetitionSeries,
  restoreRepetitionSeries,
} from "@/lib/db/repetition-series";
import {
  listDeletedTaskChecklistSteps,
  listDeletedTasks,
  restoreTask,
  restoreTaskChecklistStep,
  TaskChecklistError,
  TaskRecoveryError,
  type TaskRecoveryItem,
} from "@/lib/db/tasks";
import { getRepetitionSeriesRestoreAction } from "@/lib/repetition-series-recovery-state";
import { createClient } from "@/lib/supabase/client";
import {
  formatTaskRecoveryTimestamp,
  getTaskRecoveryExpiryMonotonicTime,
  getTaskRecoveryListViewState,
  getTaskRecoveryRestoreAction,
  isTaskRecoveryRestorableAtMonotonicTime,
  shouldClearTaskRecoveryItems,
  taskRecoveryCauseLabel,
  taskRecoveryDestinationFieldIds,
  taskRecoveryLoadErrorMessage,
  taskRecoveryRestoreErrorMessage,
} from "@/lib/task-recovery-state";
import type { TaskChecklistRecoveryItem } from "@/lib/types";
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
  boardId: string;
  timeZone: string;
  columns: RecoveryColumn[];
}

type TimedTaskRecoveryItem = TaskRecoveryItem & {
  eligibilityRequestStartedAtMonotonic: number;
};

type TimedChecklistRecoveryItem = TaskChecklistRecoveryItem & {
  eligibilityRequestStartedAtMonotonic: number;
};

type TimedColumnRecoveryItem = DeletedColumnRecoveryItem & {
  eligibilityRequestStartedAtMonotonic: number;
};

type TimedSeriesRecoveryItem = DeletedRepetitionSeriesItem & {
  eligibilityRequestStartedAtMonotonic: number;
};

export function TaskRecoveryDialog({
  open,
  onClose,
  onRestored,
  slug,
  boardId,
  timeZone,
  columns,
}: TaskRecoveryDialogProps) {
  const [items, setItems] = useState<TimedTaskRecoveryItem[]>([]);
  const [checklistItems, setChecklistItems] = useState<
    TimedChecklistRecoveryItem[]
  >([]);
  const [columnItems, setColumnItems] = useState<TimedColumnRecoveryItem[]>([]);
  const [seriesItems, setSeriesItems] = useState<TimedSeriesRecoveryItem[]>([]);
  const [selectedDestinations, setSelectedDestinations] = useState<
    Record<string, string>
  >({});
  const [isLoading, setIsLoading] = useState(false);
  const [restoringTaskId, setRestoringTaskId] = useState<string | null>(null);
  const [restoringStepId, setRestoringStepId] = useState<string | null>(null);
  const [restoringColumnId, setRestoringColumnId] = useState<string | null>(
    null,
  );
  const [restoringSeriesId, setRestoringSeriesId] = useState<string | null>(
    null,
  );
  const [selectedSeriesDestinations, setSelectedSeriesDestinations] = useState<
    Record<string, string>
  >({});
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const [monotonicNow, setMonotonicNow] = useState(0);
  const [hasCurrentEligibility, setHasCurrentEligibility] = useState(false);
  const hasCurrentEligibilityRef = useRef(false);
  const latestRefreshId = useRef(0);
  const listViewState = getTaskRecoveryListViewState({
    isLoading,
    hasError: Boolean(error),
    itemCount:
      items.length +
      checklistItems.length +
      columnItems.length +
      seriesItems.length,
    hasCurrentEligibility,
  });

  const refresh = useCallback(async () => {
    const refreshId = ++latestRefreshId.current;
    setIsLoading(true);
    hasCurrentEligibilityRef.current = false;
    setHasCurrentEligibility(false);
    setError("");
    try {
      const client = createClient();
      const eligibilityRequestStartedAtMonotonic = performance.now();
      const [listedItems, listedChecklistItems, listedColumns, listedSeries] =
        await Promise.all([
          listDeletedTasks(client, slug),
          listDeletedTaskChecklistSteps(client, slug),
          listDeletedColumns(client, slug),
          listDeletedRepetitionSeries(client, boardId),
        ]);
      if (listedSeries.status !== "available") {
        throw new Error("Series recovery is unavailable");
      }
      if (refreshId !== latestRefreshId.current) return;
      const eligibilityResponseReceivedAtMonotonic = performance.now();
      setItems(
        listedItems.map((item) => ({
          ...item,
          eligibilityRequestStartedAtMonotonic,
        })),
      );
      setChecklistItems(
        listedChecklistItems.map((item) => ({
          ...item,
          eligibilityRequestStartedAtMonotonic,
        })),
      );
      setColumnItems(
        listedColumns.map((item) => ({
          ...item,
          eligibilityRequestStartedAtMonotonic,
        })),
      );
      setSeriesItems(
        listedSeries.series.map((item) => ({
          ...item,
          eligibilityRequestStartedAtMonotonic,
        })),
      );
      setMonotonicNow(eligibilityResponseReceivedAtMonotonic);
      hasCurrentEligibilityRef.current = true;
      setHasCurrentEligibility(true);
    } catch (loadError) {
      if (refreshId !== latestRefreshId.current) return;
      const reason =
        loadError instanceof TaskRecoveryError ||
        loadError instanceof TaskChecklistError ||
        loadError instanceof ColumnRecoveryError
          ? loadError.reason
          : null;
      if (shouldClearTaskRecoveryItems(reason)) {
        setItems([]);
        setChecklistItems([]);
        setColumnItems([]);
        setSeriesItems([]);
      }
      setError(taskRecoveryLoadErrorMessage(reason));
    } finally {
      if (refreshId === latestRefreshId.current) setIsLoading(false);
    }
  }, [boardId, slug]);

  useEffect(() => {
    if (!open) return;
    setItems([]);
    setChecklistItems([]);
    setColumnItems([]);
    setSeriesItems([]);
    setSelectedDestinations({});
    setSelectedSeriesDestinations({});
    setError("");
    setMessage("");
    hasCurrentEligibilityRef.current = false;
    setHasCurrentEligibility(false);
    void refresh();
  }, [open, refresh]);

  useEffect(() => {
    if (!open || seriesItems.length === 0) return;
    const currentMonotonicTime = Math.max(performance.now(), monotonicNow);
    const nextDeadline = seriesItems
      .filter((item) => item.can_restore)
      .map((item) =>
        getTaskRecoveryExpiryMonotonicTime(
          item,
          item.eligibilityRequestStartedAtMonotonic,
        ),
      )
      .filter(
        (deadline): deadline is number =>
          deadline !== null && deadline > currentMonotonicTime,
      )
      .sort((left, right) => left - right)[0];
    if (nextDeadline === undefined) return;
    const timer = window.setTimeout(
      () => setMonotonicNow(performance.now()),
      Math.max(0, nextDeadline - currentMonotonicTime),
    );
    return () => window.clearTimeout(timer);
  }, [monotonicNow, open, seriesItems]);

  useEffect(() => {
    if (!open) return;

    let lastResumeRefreshAt = Number.NEGATIVE_INFINITY;
    const refreshAfterResume = () => {
      if (document.visibilityState !== "visible") return;
      const now = performance.now();
      if (now - lastResumeRefreshAt < 500) return;
      lastResumeRefreshAt = now;
      void refresh();
    };

    window.addEventListener("focus", refreshAfterResume);
    document.addEventListener("visibilitychange", refreshAfterResume);
    return () => {
      window.removeEventListener("focus", refreshAfterResume);
      document.removeEventListener("visibilitychange", refreshAfterResume);
    };
  }, [open, refresh]);

  useEffect(() => {
    if (
      !open ||
      (items.length === 0 &&
        checklistItems.length === 0 &&
        columnItems.length === 0)
    )
      return;

    const currentMonotonicTime = Math.max(performance.now(), monotonicNow);
    const nextDeadline = [...items, ...checklistItems, ...columnItems]
      .filter((item) => item.can_restore)
      .map((item) => {
        return getTaskRecoveryExpiryMonotonicTime(
          item,
          item.eligibilityRequestStartedAtMonotonic,
        );
      })
      .filter(
        (deadline): deadline is number =>
          deadline !== null && deadline > currentMonotonicTime,
      )
      .sort((left, right) => left - right)[0];

    if (nextDeadline === undefined) return;

    const timer = window.setTimeout(
      () => {
        setMonotonicNow(performance.now());
      },
      Math.max(0, nextDeadline - currentMonotonicTime),
    );
    return () => window.clearTimeout(timer);
  }, [checklistItems, columnItems, items, monotonicNow, open]);

  async function restore(item: TimedTaskRecoveryItem) {
    if (!hasCurrentEligibilityRef.current) {
      setError(
        "Actualizando la lista. Espera a que se confirme la disponibilidad.",
      );
      return;
    }
    const canRestore = isTaskRecoveryRestorableAtMonotonicTime(
      item,
      item.eligibilityRequestStartedAtMonotonic,
      performance.now(),
      hasCurrentEligibilityRef.current,
    );
    const selectableColumns = item.original_column_available
      ? columns
      : columns.filter((column) => column.id !== item.original_column_id);
    const action = getTaskRecoveryRestoreAction(
      { ...item, can_restore: canRestore },
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

  async function restoreChecklistStep(item: TimedChecklistRecoveryItem) {
    if (!hasCurrentEligibilityRef.current) {
      setError(
        "Actualizando la lista. Espera a que se confirme la disponibilidad.",
      );
      return;
    }
    const canRestore = isTaskRecoveryRestorableAtMonotonicTime(
      item,
      item.eligibilityRequestStartedAtMonotonic,
      performance.now(),
      hasCurrentEligibilityRef.current,
    );
    if (!canRestore) {
      setError(
        "El plazo de recuperación venció. Este paso ya no se puede recuperar.",
      );
      return;
    }
    setRestoringStepId(item.step_id);
    setError("");
    setMessage("");
    try {
      const result = await restoreTaskChecklistStep(
        createClient(),
        slug,
        generateUUID(),
        item.task_id,
        item.step_id,
      );
      if (result.status === "confirmed") {
        setMessage("Paso de checklist recuperado en su tarea.");
        try {
          await onRestored();
        } catch {
          setMessage(
            "Paso recuperado. No se pudo actualizar el tablero; vuelve a cargarlo.",
          );
        }
        await refresh();
      } else if (result.status === "expired") {
        await refresh();
        setError(
          "El plazo de recuperación venció. Este paso ya no se puede recuperar.",
        );
      } else {
        await refresh();
        setError(
          "El paso ya no está disponible para recuperar. Actualiza la lista.",
        );
      }
    } catch (restoreError) {
      await refresh();
      setError(
        restoreError instanceof TaskChecklistError &&
          restoreError.reason === "access_denied"
          ? "Ya no tienes permiso para recuperar pasos de este tablero."
          : "No se pudo confirmar si el paso se recuperó. Actualiza la lista y revisa la tarea.",
      );
    } finally {
      setRestoringStepId(null);
    }
  }

  async function recoverColumn(item: TimedColumnRecoveryItem) {
    if (!hasCurrentEligibilityRef.current) {
      setError(
        "Actualizando la lista. Espera a que se confirme la disponibilidad.",
      );
      return;
    }
    if (
      !isTaskRecoveryRestorableAtMonotonicTime(
        item,
        item.eligibilityRequestStartedAtMonotonic,
        performance.now(),
        hasCurrentEligibilityRef.current,
      )
    ) {
      setError(
        "El plazo de recuperación venció. Esta columna ya no se puede recuperar.",
      );
      return;
    }

    setRestoringColumnId(item.column_id);
    setError("");
    setMessage("");
    try {
      const result = await restoreColumn(
        createClient(),
        slug,
        generateUUID(),
        item.column_id,
      );
      if (result.status === "confirmed") {
        setMessage(
          "Columna recuperada. Las tareas trasladadas siguen en su destino.",
        );
        try {
          await onRestored();
        } catch {
          setMessage(
            "Columna recuperada. No se pudo actualizar el tablero; vuelve a cargarlo.",
          );
        }
        await refresh();
      } else if (result.status === "expired") {
        await refresh();
        setError(
          "El plazo de recuperación venció. Esta columna ya no se puede recuperar.",
        );
      } else {
        await refresh();
        setError(
          "La columna ya no está disponible para recuperar. Actualiza la lista.",
        );
      }
    } catch (restoreError) {
      await refresh();
      setError(
        restoreError instanceof ColumnRecoveryError &&
          restoreError.reason === "access_denied"
          ? "Ya no tienes permiso para recuperar columnas de este tablero."
          : "No se pudo confirmar si la columna se recuperó. Actualiza la lista antes de volver a intentarlo.",
      );
    } finally {
      setRestoringColumnId(null);
    }
  }

  async function recoverSeries(item: TimedSeriesRecoveryItem) {
    if (!hasCurrentEligibilityRef.current) {
      setError(
        "Actualizando la lista. Espera a que se confirme la disponibilidad.",
      );
      return;
    }
    const action = getRepetitionSeriesRestoreAction(
      item,
      columns.map((column) => column.id),
      selectedSeriesDestinations[item.series_id] ?? null,
      item.eligibilityRequestStartedAtMonotonic,
      performance.now(),
    );
    if (action.status === "expired") {
      setError(
        "El plazo de recuperación venció. Esta serie ya no se puede recuperar.",
      );
      return;
    }
    if (action.status === "needs_destination") {
      setError("Elige una columna vigente para las próximas apariciones.");
      return;
    }
    if (action.status === "unavailable") {
      setError(
        item.generation_available
          ? "Recupera primero las columnas que contienen ocurrencias de esta serie."
          : "Esta serie pertenece a una generación del tablero que ya no está disponible.",
      );
      return;
    }

    setRestoringSeriesId(item.series_id);
    setError("");
    setMessage("");
    try {
      const result = await restoreRepetitionSeries(createClient(), {
        operationId: generateUUID(),
        slug,
        seriesId: item.series_id,
        targetAppearanceColumnId: action.targetColumnId,
      });
      if (result.status === "confirmed") {
        setMessage(
          result.state === "stopped"
            ? "Serie recuperada. Sigue detenida; no se reactivaron próximas apariciones."
            : result.state === "finished"
              ? "Serie recuperada. Se conservaron su estado final y el historial."
              : "Serie recuperada con su historial. Se programó solo la próxima aparición vigente.",
        );
        try {
          await onRestored();
        } catch {
          setMessage(
            "Serie recuperada. No se pudo actualizar el tablero; vuelve a cargarlo.",
          );
        }
        await refresh();
      } else if (result.status === "expired") {
        await refresh();
        setError(
          "El plazo de recuperación venció. Esta serie ya no se puede recuperar.",
        );
      } else if (result.status === "needs_destination") {
        await refresh();
        setError("Elige una columna vigente para las próximas apariciones.");
      } else if (result.status === "needs_parent") {
        await refresh();
        setError(
          "Recupera primero las columnas y la generación original del tablero.",
        );
      } else {
        await refresh();
        setError(
          "La serie ya no está disponible para recuperar. Actualiza la lista.",
        );
      }
    } catch {
      await refresh();
      setError(
        "No se pudo confirmar si la serie se recuperó. Actualiza la lista antes de volver a intentarlo.",
      );
    } finally {
      setRestoringSeriesId(null);
    }
  }

  return (
    <Modal
      open={open}
      onClose={onClose}
      title="Recuperación del tablero"
      fullScreenMobile
      closeLabel="Cerrar recuperación del tablero"
    >
      <div className="space-y-5 text-text-primary">
        <p className="text-sm text-text-secondary">
          Las tareas, columnas, pasos y series se pueden recuperar durante siete
          días desde su eliminación. Abrir esta lista no restaura nada
          automáticamente.
        </p>

        <div className="flex items-center justify-between gap-3">
          <h3 className="font-semibold text-sm">Elementos eliminados</h3>
          <Button
            type="button"
            onClick={() => void refresh()}
            disabled={
              isLoading ||
              restoringTaskId !== null ||
              restoringStepId !== null ||
              restoringColumnId !== null ||
              restoringSeriesId !== null
            }
            aria-label="Actualizar recuperación"
            title="Actualizar recuperación"
            className="min-h-10"
          >
            <IconRefresh size={16} aria-hidden="true" />
            Actualizar
          </Button>
        </div>

        {hasCurrentEligibility && seriesItems.length > 0 ? (
          <section aria-labelledby="deleted-repetition-series-heading">
            <h3
              id="deleted-repetition-series-heading"
              className="mb-2 font-semibold text-sm"
            >
              Series eliminadas
            </h3>
            <ul className="divide-y divide-border rounded-lg border border-border">
              {seriesItems.map((item) => {
                const selectedDestination =
                  selectedSeriesDestinations[item.series_id] ?? null;
                const action = getRepetitionSeriesRestoreAction(
                  item,
                  columns.map((column) => column.id),
                  selectedDestination,
                  item.eligibilityRequestStartedAtMonotonic,
                  monotonicNow,
                );
                const isRestoring = restoringSeriesId === item.series_id;
                const destinationFieldId = `series-recovery-destination-${item.series_id}`;
                return (
                  <li
                    key={item.series_id}
                    className="flex flex-col gap-4 p-4 sm:flex-row sm:items-start sm:justify-between"
                  >
                    <div className="min-w-0 space-y-1">
                      <p className="break-words font-medium text-sm">
                        {item.title || "Serie sin título"}
                      </p>
                      <p className="text-text-muted text-xs">
                        {item.occurrence_count} ocurrencias ·{" "}
                        {item.state === "active"
                          ? "Estaba activa"
                          : item.state === "stopped"
                            ? "Estaba detenida"
                            : "Estaba finalizada"}
                      </p>
                      <p className="text-text-muted text-xs">
                        Eliminada:{" "}
                        {formatTaskRecoveryTimestamp(item.deleted_at, timeZone)}
                      </p>
                      <p className="text-text-muted text-xs">
                        Vence:{" "}
                        {formatTaskRecoveryTimestamp(item.expires_at, timeZone)}
                      </p>
                      {action.status === "expired" ? (
                        <p className="text-priority-urgent text-xs">
                          El plazo venció; no se puede recuperar.
                        </p>
                      ) : action.status === "unavailable" ? (
                        <p className="text-text-muted text-xs">
                          {item.generation_available
                            ? "Recupera primero las columnas de las ocurrencias."
                            : "La generación original del tablero ya no está disponible."}
                        </p>
                      ) : action.status === "needs_destination" ? (
                        columns.length > 0 ? (
                          <div className="space-y-1 pt-2">
                            <label
                              htmlFor={destinationFieldId}
                              className="block text-text-secondary text-xs"
                            >
                              Columna para próximas apariciones
                            </label>
                            <select
                              id={destinationFieldId}
                              value={selectedDestination ?? ""}
                              onChange={(event) =>
                                setSelectedSeriesDestinations((current) => ({
                                  ...current,
                                  [item.series_id]: event.target.value,
                                }))
                              }
                              disabled={restoringSeriesId !== null}
                              className="min-h-10 w-full rounded-md border border-border bg-surface-base px-3 text-sm focus:border-accent focus:outline-none sm:min-w-64"
                            >
                              <option value="">Elige una columna</option>
                              {columns.map((column) => (
                                <option key={column.id} value={column.id}>
                                  {column.title}
                                </option>
                              ))}
                            </select>
                          </div>
                        ) : (
                          <p className="pt-2 text-text-muted text-xs">
                            Crea una columna vigente antes de recuperar esta
                            serie.
                          </p>
                        )
                      ) : null}
                    </div>
                    {action.status === "restore" ||
                    action.status === "needs_destination" ? (
                      <Button
                        type="button"
                        variant="primary"
                        onClick={() => void recoverSeries(item)}
                        disabled={
                          restoringTaskId !== null ||
                          restoringStepId !== null ||
                          restoringColumnId !== null ||
                          restoringSeriesId !== null ||
                          action.status !== "restore"
                        }
                        aria-label={`Recuperar serie: ${item.title || "Sin título"}`}
                        className="min-h-11 shrink-0"
                      >
                        {isRestoring ? "Recuperando…" : "Recuperar serie"}
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
          </section>
        ) : null}

        {listViewState === "loading" ? (
          <output className="text-sm text-text-muted" aria-live="polite">
            Cargando elementos eliminados…
          </output>
        ) : listViewState === "ready" && items.length > 0 ? (
          <ul className="divide-y divide-border rounded-lg border border-border">
            {items.map((item) => {
              const selectableColumns = item.original_column_available
                ? columns
                : columns.filter(
                    (column) => column.id !== item.original_column_id,
                  );
              const selectedDestination =
                selectedDestinations[item.task_id] ?? null;
              const canRestore = isTaskRecoveryRestorableAtMonotonicTime(
                item,
                item.eligibilityRequestStartedAtMonotonic,
                monotonicNow,
                hasCurrentEligibility,
              );
              const action = getTaskRecoveryRestoreAction(
                { ...item, can_restore: canRestore },
                selectableColumns.map((column) => column.id),
                selectedDestination,
              );
              const requiresDestination =
                canRestore && !item.original_column_available;
              const isRestoring = restoringTaskId === item.task_id;
              const destinationFieldIds = taskRecoveryDestinationFieldIds(
                item.task_id,
              );

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
                    {!canRestore ? (
                      <p className="text-priority-urgent text-xs">
                        El plazo venció; no se puede recuperar.
                      </p>
                    ) : requiresDestination ? (
                      selectableColumns.length > 0 ? (
                        <div className="space-y-1 pt-2">
                          <label
                            id={destinationFieldIds.labelId}
                            htmlFor={destinationFieldIds.htmlFor}
                            className="block text-text-secondary text-xs"
                          >
                            Columna de destino
                          </label>
                          <select
                            id={destinationFieldIds.selectId}
                            value={selectedDestination ?? ""}
                            onChange={(event) =>
                              setSelectedDestinations((current) => ({
                                ...current,
                                [item.task_id]: event.target.value,
                              }))
                            }
                            disabled={
                              restoringTaskId !== null ||
                              restoringStepId !== null
                            }
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

                  {canRestore ? (
                    <Button
                      type="button"
                      variant="primary"
                      onClick={() => void restore(item)}
                      disabled={
                        restoringTaskId !== null ||
                        restoringStepId !== null ||
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
            No hay tareas, pasos, columnas ni series eliminadas para recuperar
            en este tablero.
          </p>
        ) : null}

        {hasCurrentEligibility && columnItems.length > 0 ? (
          <section aria-labelledby="deleted-columns-heading">
            <h3
              id="deleted-columns-heading"
              className="mb-2 font-semibold text-sm"
            >
              Columnas eliminadas
            </h3>
            <ul className="divide-y divide-border rounded-lg border border-border">
              {columnItems.map((item) => {
                const canRestore = isTaskRecoveryRestorableAtMonotonicTime(
                  item,
                  item.eligibilityRequestStartedAtMonotonic,
                  monotonicNow,
                  hasCurrentEligibility,
                );
                const destination = columns.find(
                  (column) => column.id === item.destination_column_id,
                );
                const isRestoring = restoringColumnId === item.column_id;
                return (
                  <li
                    key={item.column_id}
                    className="flex flex-col gap-4 p-4 sm:flex-row sm:items-center sm:justify-between"
                  >
                    <div className="min-w-0 space-y-1">
                      <p className="font-medium text-sm">{item.title}</p>
                      <p className="text-text-muted text-xs">Tipo: Columna</p>
                      <p className="text-text-muted text-xs">
                        Eliminada:{" "}
                        {formatTaskRecoveryTimestamp(item.deleted_at, timeZone)}
                      </p>
                      <p className="text-text-muted text-xs">
                        Vence:{" "}
                        {formatTaskRecoveryTimestamp(item.expires_at, timeZone)}
                      </p>
                      {item.moved_task_count > 0 ? (
                        <p className="text-text-muted text-xs">
                          Se trasladaron {item.moved_task_count}{" "}
                          {item.moved_task_count === 1 ? "tarea" : "tareas"}
                          {destination
                            ? ` a “${destination.title}”`
                            : " a otra columna"}
                          . Recuperar la estructura no revierte el traslado.
                        </p>
                      ) : null}
                      {!canRestore ? (
                        <p className="text-priority-urgent text-xs">
                          El plazo venció; no se puede recuperar.
                        </p>
                      ) : null}
                    </div>
                    {canRestore ? (
                      <Button
                        type="button"
                        variant="primary"
                        onClick={() => void recoverColumn(item)}
                        disabled={
                          restoringTaskId !== null ||
                          restoringStepId !== null ||
                          restoringColumnId !== null
                        }
                        aria-label={`Recuperar columna: ${item.title}`}
                        className="min-h-11 shrink-0"
                      >
                        {isRestoring ? "Recuperando…" : "Recuperar columna"}
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
          </section>
        ) : null}

        {hasCurrentEligibility && checklistItems.length > 0 ? (
          <section aria-labelledby="deleted-checklist-steps-heading">
            <h3
              id="deleted-checklist-steps-heading"
              className="mb-2 font-semibold text-sm"
            >
              Pasos de checklist eliminados
            </h3>
            <ul className="divide-y divide-border rounded-lg border border-border">
              {checklistItems.map((item) => {
                const canRestore = isTaskRecoveryRestorableAtMonotonicTime(
                  item,
                  item.eligibilityRequestStartedAtMonotonic,
                  monotonicNow,
                  hasCurrentEligibility,
                );
                const isRestoring = restoringStepId === item.step_id;
                return (
                  <li
                    key={`${item.task_id}:${item.step_id}`}
                    className="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between"
                  >
                    <div className="min-w-0 space-y-1">
                      <p className="break-words font-medium text-sm">
                        {item.text}
                      </p>
                      <p className="text-text-muted text-xs">
                        Tipo: Paso de checklist · Tarea: {item.task_title}
                      </p>
                      <p className="text-text-muted text-xs">
                        Causa: Eliminación solicitada
                      </p>
                      <p className="text-text-muted text-xs">
                        Estado: {item.is_completed ? "Marcado" : "Pendiente"}
                      </p>
                      <p className="text-text-muted text-xs">
                        Eliminado:{" "}
                        {formatTaskRecoveryTimestamp(item.deleted_at, timeZone)}
                      </p>
                      <p className="text-text-muted text-xs">
                        Vence:{" "}
                        {formatTaskRecoveryTimestamp(item.expires_at, timeZone)}
                      </p>
                      {!canRestore ? (
                        <p className="text-priority-urgent text-xs">
                          El plazo venció; no se puede recuperar.
                        </p>
                      ) : null}
                    </div>
                    {canRestore ? (
                      <Button
                        type="button"
                        variant="primary"
                        onClick={() => void restoreChecklistStep(item)}
                        disabled={
                          restoringTaskId !== null || restoringStepId !== null
                        }
                        aria-label={`Recuperar paso: ${item.text}`}
                        className="min-h-11 shrink-0"
                      >
                        {isRestoring ? "Recuperando…" : "Recuperar paso"}
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
          </section>
        ) : null}

        {error ? (
          <p
            className="rounded-lg border border-priority-urgent/30 bg-priority-urgent/10 p-3 text-priority-urgent text-sm"
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
