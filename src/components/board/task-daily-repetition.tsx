"use client";

import { IconRepeat } from "@tabler/icons-react";
import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Modal } from "@/components/ui/modal";
import type { DailyRepetitionOperationStore } from "@/lib/daily-repetition-state";
import type {
  DailyRepetitionCreateCommand,
  DailyRepetitionCreateResult,
  DailyRepetitionPreview,
  DailyRepetitionStatus,
} from "@/lib/db/daily-repetition";
import { DailyRepetitionError } from "@/lib/db/daily-repetition";
import { formatTaskDueDate } from "@/lib/task-date";
import type { Task } from "@/lib/types";
import { generateUUID } from "@/lib/utils";

interface TaskDailyRepetitionProps {
  task: Task;
  slug: string;
  boardToday: string;
  boardTimeZone: string;
  isOnline: boolean;
  isDisabled: boolean;
  hasUnsavedChanges: boolean;
  operations: DailyRepetitionOperationStore;
  onLoad: (taskId: string) => Promise<DailyRepetitionStatus>;
  onPreview: (
    taskId: string,
    startOn: string,
    endOn: string | null,
    occurrenceLimit: number | null,
  ) => Promise<DailyRepetitionPreview>;
  onCreate: (
    command: DailyRepetitionCreateCommand,
  ) => Promise<DailyRepetitionCreateResult>;
}

type FinalMode = "count" | "date" | "none";

function stateLabel(state: string) {
  switch (state) {
    case "current":
      return "Vigente";
    case "replaced":
      return "Reemplazada";
    case "excluded":
      return "Excluida por borrado";
    case "purged":
      return "Purgada";
    case "transferred":
      return "Convertida en otra serie";
    case "active":
      return "Activa";
    case "stopped":
      return "Detenida";
    case "finished":
      return "Finalizada";
    default:
      return state;
  }
}

function confirmationText(
  preview: DailyRepetitionPreview | null,
  pending: {
    changeStart: boolean;
    previousSeriesId: string | null;
    startOn: string;
  },
) {
  const details: string[] = [];
  if (pending.changeStart) {
    details.push(
      `La tarea actual conservará su identidad y su fecha límite pasará a ${formatTaskDueDate(preview?.proposed_start_on ?? pending.startOn) ?? pending.startOn}.`,
    );
  }
  if (pending.previousSeriesId) {
    details.push(
      "La serie anterior conservará su historial y esta tarjeta iniciará una serie nueva.",
    );
  }
  return details.join(" ");
}

export function TaskDailyRepetition({
  task,
  slug,
  boardToday,
  boardTimeZone,
  isOnline,
  isDisabled,
  hasUnsavedChanges,
  operations,
  onLoad,
  onPreview,
  onCreate,
}: TaskDailyRepetitionProps) {
  const [status, setStatus] = useState<DailyRepetitionStatus | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isWorking, setIsWorking] = useState(false);
  const [showSetup, setShowSetup] = useState(false);
  const [startOn, setStartOn] = useState(task.due_on ?? boardToday);
  const [finalMode, setFinalMode] = useState<FinalMode>("count");
  const [occurrenceCount, setOccurrenceCount] = useState("3");
  const [endOn, setEndOn] = useState("");
  const [preview, setPreview] = useState<DailyRepetitionPreview | null>(null);
  const [notice, setNotice] = useState("");
  const [pendingConfirmation, setPendingConfirmation] = useState<{
    changeStart: boolean;
    previousSeriesId: string | null;
    startOn: string;
  } | null>(null);
  const [retryCommand, setRetryCommand] =
    useState<DailyRepetitionCreateCommand | null>(null);
  const operationIdRef = useRef<string | null>(null);

  useEffect(() => {
    let active = true;
    const pending = operations.get(task.id);
    setIsLoading(true);
    setShowSetup(pending !== null);
    setStartOn(pending?.start_on ?? task.due_on ?? boardToday);
    setFinalMode("count");
    setOccurrenceCount(String(pending?.occurrence_limit ?? 3));
    setEndOn(pending?.end_on ?? "");
    setPreview(null);
    setNotice(
      pending
        ? "Hay una operación pendiente de confirmación. Reintenta la misma solicitud para revisar su resultado."
        : "",
    );
    setPendingConfirmation(null);
    setRetryCommand(pending);
    operationIdRef.current = pending?.operation_id ?? null;
    if (pending?.end_on) setFinalMode("date");
    else if (pending?.occurrence_limit === null) setFinalMode("none");
    void onLoad(task.id)
      .then((result) => {
        if (!active) return;
        setStatus(result);
        if (
          pending &&
          result.status === "available" &&
          result.state === "active"
        ) {
          operations.clear(task.id);
          setRetryCommand(null);
          setShowSetup(false);
          setNotice(
            "La serie ya está activa; se conservó la operación sin duplicarla.",
          );
        }
      })
      .catch(() => {
        if (active) setStatus({ status: "unavailable" });
      })
      .finally(() => {
        if (active) setIsLoading(false);
      });
    return () => {
      active = false;
    };
  }, [onLoad, operations, task.due_on, task.id, boardToday]);

  const finalSelection = () => {
    if (finalMode === "count") {
      const count = Number(occurrenceCount);
      if (!Number.isSafeInteger(count) || count < 1) return null;
      return { endOn: null, occurrenceLimit: count };
    }
    if (finalMode === "date") {
      if (!endOn) return null;
      return { endOn, occurrenceLimit: null };
    }
    return { endOn: null, occurrenceLimit: null };
  };

  async function loadPreview() {
    if (!isOnline || isDisabled || hasUnsavedChanges || !startOn) return;
    const final = finalSelection();
    if (!final) {
      setNotice(
        "Revisa la cantidad total o la fecha final antes de continuar.",
      );
      return;
    }
    setIsWorking(true);
    setNotice("");
    setPreview(null);
    try {
      const nextPreview = await onPreview(
        task.id,
        startOn,
        final.endOn,
        final.occurrenceLimit,
      );
      if (nextPreview.status !== "available") {
        setNotice(
          "No se pudo consultar esta tarea para preparar la repetición.",
        );
        return;
      }
      setPreview(nextPreview);
    } catch {
      setNotice(
        "No se pudo generar la vista previa. Los datos de la tarea no cambiaron.",
      );
    } finally {
      setIsWorking(false);
    }
  }

  function commandFor(
    confirmStartChange: boolean,
    previousSeriesId: string | null,
  ): DailyRepetitionCreateCommand | null {
    const final = finalSelection();
    if (!final) return null;
    operationIdRef.current ??= generateUUID();
    return {
      operation_id: operationIdRef.current,
      slug,
      task_id: task.id,
      start_on: startOn,
      end_on: final.endOn,
      occurrence_limit: final.occurrenceLimit,
      expected_due_on_version: task.field_versions.due_on,
      confirm_start_change: confirmStartChange,
      previous_series_id: previousSeriesId,
    };
  }

  async function submitCreate(command: DailyRepetitionCreateCommand) {
    setIsWorking(true);
    setNotice("");
    try {
      const result = await onCreate(command);
      setRetryCommand(null);
      operations.clear(task.id);
      if (result.status === "confirmed") {
        operationIdRef.current = null;
        setPendingConfirmation(null);
        setPreview(null);
        setShowSetup(false);
        setNotice("La repetición diaria quedó guardada.");
        setStatus(await onLoad(task.id));
        return;
      }
      if (result.status === "confirmation_required") {
        operationIdRef.current = command.operation_id;
        setPendingConfirmation({
          changeStart: result.confirmation === "change_current_due_date",
          startOn: command.start_on,
          previousSeriesId:
            result.confirmation === "new_series_from_stopped"
              ? (result.previous_series_id ??
                preview?.previous_series_id ??
                null)
              : command.previous_series_id,
        });
        return;
      }
      if (result.status === "conflict") {
        operationIdRef.current = null;
        setNotice(
          "La tarea o la serie cambió mientras preparabas la repetición. Actualiza la vista previa y revisa el estado actual.",
        );
        setPreview(null);
        setStatus(await onLoad(task.id));
        return;
      }
      operationIdRef.current = null;
      setNotice(
        result.status === "expired_unknown"
          ? "No se pudo confirmar una operación anterior. Revisa el estado de la serie antes de intentarlo de nuevo."
          : "La tarea no está disponible para crear una repetición.",
      );
      setStatus(await onLoad(task.id));
    } catch (error) {
      if (
        error instanceof DailyRepetitionError &&
        error.reason === "rejected"
      ) {
        setNotice(
          "No se guardó la repetición. Revisa las fechas y vuelve a preparar la vista previa.",
        );
        setRetryCommand(null);
        operations.clear(task.id);
        operationIdRef.current = null;
      } else if (
        error instanceof DailyRepetitionError &&
        error.reason === "access_denied"
      ) {
        setNotice(
          "Tu acceso al tablero cambió. Actualiza la página antes de continuar.",
        );
        operations.clear(task.id);
      } else {
        operations.set(command);
        setRetryCommand(command);
        setNotice(
          "No se pudo confirmar el resultado. Reintenta la misma operación para evitar duplicados.",
        );
      }
    } finally {
      setIsWorking(false);
    }
  }

  async function createSeries() {
    if (!isOnline || isDisabled || hasUnsavedChanges || !preview) return;
    if (
      preview.requires_start_confirmation ||
      preview.requires_previous_series_confirmation
    ) {
      setPendingConfirmation({
        changeStart: Boolean(preview.requires_start_confirmation),
        startOn: preview.proposed_start_on ?? startOn,
        previousSeriesId: preview.requires_previous_series_confirmation
          ? (preview.previous_series_id ?? null)
          : null,
      });
      return;
    }
    const command = commandFor(false, null);
    if (!command) return;
    await submitCreate(command);
  }

  async function confirmSeries() {
    if (!pendingConfirmation || isWorking) return;
    const command = commandFor(
      pendingConfirmation.changeStart,
      pendingConfirmation.previousSeriesId,
    );
    if (command) await submitCreate(command);
  }

  async function retryCreate() {
    if (!retryCommand || isWorking) return;
    await submitCreate(retryCommand);
  }

  const activeSeries =
    status?.status === "available" && status.state === "active";
  const canCreate =
    status?.status === "not_repeating" ||
    (status?.status === "available" && status.state !== "active");

  return (
    <section
      className="border-border border-t pt-3 sm:col-span-2"
      aria-labelledby="task-daily-repetition-heading"
    >
      <h3
        id="task-daily-repetition-heading"
        className="mb-2 flex items-center gap-2 font-semibold text-sm text-text-primary"
      >
        <IconRepeat size={16} aria-hidden="true" /> Repetición diaria
      </h3>
      {isLoading ? (
        <p className="text-text-muted text-xs" aria-live="polite">
          Consultando el estado de la serie…
        </p>
      ) : activeSeries && status?.status === "available" ? (
        <div className="space-y-3 text-sm">
          <p className="text-text-secondary">
            Serie activa · próxima ocurrencia:{" "}
            {formatTaskDueDate(status.next_due_on ?? null) ??
              status.next_due_on}{" "}
            · zona del tablero: {boardTimeZone}.
          </p>
          {status.diagnostic &&
          ["retry_wait", "dead_letter"].includes(status.diagnostic.status) ? (
            <output
              aria-live="polite"
              className="rounded-md border border-priority-medium/40 bg-priority-medium/10 p-3 text-text-secondary text-xs"
            >
              {status.diagnostic.status === "retry_wait"
                ? "Una ejecución falló y está programada para reintento."
                : "La ejecución necesita revisión antes de continuar."}
              {status.diagnostic.last_error_code
                ? ` Código: ${status.diagnostic.last_error_code}.`
                : ""}
            </output>
          ) : null}
          <ol className="space-y-1 text-text-muted text-xs">
            {(status.occurrences ?? []).slice(-5).map((occurrence) => (
              <li key={`${occurrence.occurrence_on}-${occurrence.task_id}`}>
                {formatTaskDueDate(occurrence.occurrence_on) ??
                  occurrence.occurrence_on}
                : {stateLabel(occurrence.state)}
                {occurrence.due_on_override
                  ? ` · fecha excepcional ${formatTaskDueDate(occurrence.due_on_override)}`
                  : ""}
              </li>
            ))}
          </ol>
        </div>
      ) : status?.status === "unavailable" ? (
        <output
          className="block text-priority-medium text-xs"
          aria-live="polite"
        >
          No se pudo consultar el estado. Actualiza el tablero antes de cambiar
          la repetición.
        </output>
      ) : (
        <div className="space-y-3">
          {status?.status === "available" ? (
            <p className="text-sm text-text-secondary">
              Serie {stateLabel(status.state ?? "")}. El historial se conserva
              al programar una nueva serie.
            </p>
          ) : null}
          {hasUnsavedChanges ? (
            <p className="text-text-muted text-xs">
              Guarda primero los cambios de esta tarjeta para convertirla en la
              primera ocurrencia.
            </p>
          ) : null}
          {!showSetup ? (
            <Button
              type="button"
              variant="ghost"
              onClick={() => {
                setShowSetup(true);
                setNotice("");
              }}
              disabled={
                !canCreate ||
                isDisabled ||
                isWorking ||
                !isOnline ||
                hasUnsavedChanges
              }
            >
              Repetir diariamente
            </Button>
          ) : (
            <div className="space-y-4 rounded-md border border-border p-3">
              <div className="grid gap-3 sm:grid-cols-2">
                <label
                  className="flex flex-col gap-1.5 font-semibold text-text-muted text-xs"
                  htmlFor="daily-repetition-start"
                >
                  Primera fecha · zona {boardTimeZone}
                  <input
                    id="daily-repetition-start"
                    type="date"
                    value={startOn}
                    disabled={isWorking || Boolean(retryCommand)}
                    onChange={(event) => {
                      setStartOn(event.target.value);
                      setPreview(null);
                    }}
                    className="h-10 rounded-md border border-border bg-transparent px-3 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
                  />
                </label>
                <label
                  className="flex flex-col gap-1.5 font-semibold text-text-muted text-xs"
                  htmlFor="daily-repetition-final-mode"
                >
                  Final de la serie
                  <select
                    id="daily-repetition-final-mode"
                    value={finalMode}
                    disabled={isWorking || Boolean(retryCommand)}
                    onChange={(event) => {
                      setFinalMode(event.target.value as FinalMode);
                      setPreview(null);
                    }}
                    className="h-10 rounded-md border border-border bg-surface-base px-3 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
                  >
                    <option value="count">
                      Cantidad total incluyendo esta tarea
                    </option>
                    <option value="date">
                      Hasta una fecha final inclusiva
                    </option>
                    <option value="none">Sin fecha final</option>
                  </select>
                </label>
              </div>
              {finalMode === "count" ? (
                <label
                  className="flex max-w-xs flex-col gap-1.5 font-semibold text-text-muted text-xs"
                  htmlFor="daily-repetition-count"
                >
                  Ocurrencias totales · esta tarea cuenta como la primera
                  <input
                    id="daily-repetition-count"
                    type="number"
                    min={1}
                    max={2147483648}
                    value={occurrenceCount}
                    disabled={isWorking || Boolean(retryCommand)}
                    onChange={(event) => {
                      setOccurrenceCount(event.target.value);
                      setPreview(null);
                    }}
                    className="h-10 rounded-md border border-border bg-transparent px-3 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
                  />
                </label>
              ) : null}
              {finalMode === "date" ? (
                <label
                  className="flex max-w-xs flex-col gap-1.5 font-semibold text-text-muted text-xs"
                  htmlFor="daily-repetition-end"
                >
                  Última fecha, inclusive
                  <input
                    id="daily-repetition-end"
                    type="date"
                    min={startOn}
                    value={endOn}
                    disabled={isWorking || Boolean(retryCommand)}
                    onChange={(event) => {
                      setEndOn(event.target.value);
                      setPreview(null);
                    }}
                    className="h-10 rounded-md border border-border bg-transparent px-3 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
                  />
                </label>
              ) : null}
              {preview ? (
                <div
                  className="rounded-md bg-surface-base p-3 text-sm"
                  aria-live="polite"
                >
                  <p className="font-medium text-text-primary">
                    Actual:{" "}
                    {formatTaskDueDate(preview.current?.due_on ?? null) ??
                      preview.current?.due_on}{" "}
                    · conserva esta tarjeta.
                  </p>
                  <p className="mt-1 text-text-secondary">
                    Próximas fechas:{" "}
                    {preview.future_dates?.length
                      ? preview.future_dates
                          .map((date) => formatTaskDueDate(date) ?? date)
                          .join(", ")
                      : "ninguna dentro de la vista previa"}
                    .
                  </p>
                  <p className="mt-1 text-text-muted text-xs">
                    {preview.occurrence_limit !== null &&
                    preview.occurrence_limit !== undefined
                      ? `${preview.remaining_dates_after_current ?? 0} fechas futuras · ${preview.occurrence_limit} ocurrencias totales.`
                      : preview.final_on
                        ? `Final inclusivo: ${formatTaskDueDate(preview.final_on ?? null) ?? preview.final_on}.`
                        : "Sin fecha final."}
                    {preview.start_in_past
                      ? " La primera fecha ya pasó; la ejecución diaria no acumulará atrasos."
                      : ""}
                  </p>
                </div>
              ) : null}
              {notice ? (
                <output
                  className="block text-priority-medium text-xs"
                  aria-live="polite"
                >
                  {notice}
                </output>
              ) : null}
              <div className="flex flex-wrap gap-2">
                <Button
                  type="button"
                  variant="ghost"
                  onClick={() => void loadPreview()}
                  disabled={
                    !isOnline ||
                    isWorking ||
                    isDisabled ||
                    hasUnsavedChanges ||
                    Boolean(retryCommand)
                  }
                >
                  {isWorking ? "Consultando…" : "Vista previa"}
                </Button>
                {preview ? (
                  <Button
                    type="button"
                    onClick={() => void createSeries()}
                    disabled={
                      !isOnline ||
                      isWorking ||
                      isDisabled ||
                      hasUnsavedChanges ||
                      Boolean(retryCommand)
                    }
                  >
                    Crear serie
                  </Button>
                ) : null}
                {retryCommand ? (
                  <Button
                    type="button"
                    onClick={() => void retryCreate()}
                    disabled={!isOnline || isWorking}
                  >
                    Reintentar la misma operación
                  </Button>
                ) : null}
                <Button
                  type="button"
                  variant="ghost"
                  onClick={() => {
                    setShowSetup(false);
                    setPreview(null);
                    setNotice("");
                    setPendingConfirmation(null);
                  }}
                  disabled={isWorking}
                >
                  Cancelar
                </Button>
              </div>
            </div>
          )}
        </div>
      )}
      {notice && !showSetup && !activeSeries ? (
        <output
          className="mt-2 block text-priority-medium text-xs"
          aria-live="polite"
        >
          {notice}
        </output>
      ) : null}
      <Modal
        open={pendingConfirmation !== null}
        onClose={() => setPendingConfirmation(null)}
        title="Confirmar primera ocurrencia"
        closeLabel="Cerrar confirmación de repetición"
      >
        <p className="mb-5 text-sm text-text-secondary leading-6">
          {pendingConfirmation
            ? confirmationText(preview, pendingConfirmation)
            : ""}
          {preview?.requires_previous_series_confirmation &&
          !pendingConfirmation?.previousSeriesId
            ? " Se conservará la serie anterior y se creará una nueva desde esta tarjeta."
            : ""}
          {preview?.requires_start_confirmation &&
          !pendingConfirmation?.changeStart
            ? ` La fecha actual se ajustará a ${formatTaskDueDate(preview.proposed_start_on ?? pendingConfirmation?.startOn ?? null) ?? pendingConfirmation?.startOn}.`
            : ""}
        </p>
        <div className="flex justify-end gap-2">
          <Button
            type="button"
            variant="ghost"
            onClick={() => setPendingConfirmation(null)}
            disabled={isWorking}
          >
            Cancelar
          </Button>
          <Button
            type="button"
            variant="primary"
            onClick={() => void confirmSeries()}
            disabled={isWorking || !isOnline}
          >
            {isWorking ? "Guardando…" : "Confirmar y crear"}
          </Button>
        </div>
      </Modal>
    </section>
  );
}
