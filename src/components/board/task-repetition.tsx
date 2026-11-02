"use client";

import { IconRepeat } from "@tabler/icons-react";
import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Modal } from "@/components/ui/modal";
import type { RepetitionOperationStore } from "@/lib/daily-repetition-state";
import type {
  RepetitionCreateCommand,
  RepetitionCreateResult,
  RepetitionPattern,
  RepetitionPreview,
  RepetitionStatus,
} from "@/lib/db/daily-repetition";
import { RepetitionError } from "@/lib/db/daily-repetition";
import {
  createRepetitionPattern,
  ordinalWeekdayAdjective,
} from "@/lib/repetition-pattern";
import { formatTaskDueDate } from "@/lib/task-date";
import type { Task } from "@/lib/types";
import { generateUUID } from "@/lib/utils";

interface TaskRepetitionProps {
  task: Task;
  slug: string;
  boardToday: string;
  boardTimeZone: string;
  isOnline: boolean;
  isDisabled: boolean;
  hasUnsavedChanges: boolean;
  operations: RepetitionOperationStore;
  onLoad: (taskId: string) => Promise<RepetitionStatus>;
  onPreview: (
    taskId: string,
    startOn: string,
    endOn: string | null,
    occurrenceLimit: number | null,
    pattern: RepetitionPattern,
  ) => Promise<RepetitionPreview>;
  onCreate: (
    command: RepetitionCreateCommand,
  ) => Promise<RepetitionCreateResult>;
}

type FinalMode = "count" | "date" | "none";
type RepetitionFrequency = RepetitionPattern["frequency"];

const WEEKDAYS = [
  { value: 1, label: "lunes" },
  { value: 2, label: "martes" },
  { value: 3, label: "miércoles" },
  { value: 4, label: "jueves" },
  { value: 5, label: "viernes" },
  { value: 6, label: "sábado" },
  { value: 7, label: "domingo" },
] as const;

const MONTHS = [
  "enero",
  "febrero",
  "marzo",
  "abril",
  "mayo",
  "junio",
  "julio",
  "agosto",
  "septiembre",
  "octubre",
  "noviembre",
  "diciembre",
] as const;

const ORDINALS = [
  { value: 1, label: "primero" },
  { value: 2, label: "segundo" },
  { value: 3, label: "tercero" },
  { value: 4, label: "cuarto" },
  { value: 5, label: "quinto" },
  { value: -1, label: "último" },
] as const;

function isoWeekday(date: string): number {
  const [year, month, day] = date.split("-").map(Number);
  const utcDate = new Date(0);
  utcDate.setUTCFullYear(year, month - 1, day);
  return utcDate.getUTCDay() || 7;
}

function patternLabel(pattern: RepetitionPattern | undefined): string | null {
  if (!pattern) return null;
  if (pattern.frequency === "daily") {
    return pattern.interval === 1
      ? "Cada día"
      : `Cada ${pattern.interval} días`;
  }
  if (pattern.frequency === "monthly" || pattern.frequency === "yearly") {
    const unit = pattern.frequency === "monthly" ? "mes" : "año";
    const pluralUnit = pattern.frequency === "monthly" ? "meses" : "años";
    const interval = String(pattern.interval);
    const cadence =
      interval === "1" ? `cada ${unit}` : `cada ${interval} ${pluralUnit}`;
    if ("day_of_month" in pattern) {
      if (pattern.frequency === "monthly") {
        if (pattern.day_of_month === -1) return `El último día de ${cadence}`;
        return `${cadence} · día ${pattern.day_of_month}`;
      }
      if (pattern.day_of_month === -1) {
        return `El último día de ${MONTHS[pattern.month - 1]}, ${cadence}`;
      }
      return `${cadence} · ${pattern.day_of_month} de ${MONTHS[pattern.month - 1]}`;
    }
    const ordinal = ordinalWeekdayAdjective(pattern.ordinal);
    const weekday = WEEKDAYS.find(
      (item) => item.value === pattern.weekday,
    )?.label;
    if (!ordinal || !weekday) return cadence;
    if (pattern.frequency === "monthly") {
      return `El ${ordinal} ${weekday} de ${cadence}`;
    }
    return `El ${ordinal} ${weekday} de ${MONTHS[pattern.month - 1]}, ${cadence}`;
  }
  const days = pattern.weekdays
    .map((value) => WEEKDAYS.find((day) => day.value === value))
    .filter((day) => day !== undefined)
    .map((day) => day.label)
    .join(", ");
  return `Cada ${pattern.interval === 1 ? "semana" : `${pattern.interval} semanas`} · ${days}`;
}

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
  preview: RepetitionPreview | null,
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

export function TaskRepetition({
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
}: TaskRepetitionProps) {
  const [status, setStatus] = useState<RepetitionStatus | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isWorking, setIsWorking] = useState(false);
  const [showSetup, setShowSetup] = useState(false);
  const [startOn, setStartOn] = useState(task.due_on ?? boardToday);
  const [frequency, setFrequency] = useState<RepetitionFrequency>("daily");
  const [interval, setInterval] = useState("1");
  const [calendarMode, setCalendarMode] = useState<"day" | "ordinal">("day");
  const [dayOfMonth, setDayOfMonth] = useState("1");
  const [month, setMonth] = useState("1");
  const [ordinal, setOrdinal] = useState("1");
  const [ordinalWeekday, setOrdinalWeekday] = useState("1");
  const [weekdays, setWeekdays] = useState<number[]>(() => [
    isoWeekday(task.due_on ?? boardToday),
  ]);
  const [finalMode, setFinalMode] = useState<FinalMode>("count");
  const [occurrenceCount, setOccurrenceCount] = useState("3");
  const [endOn, setEndOn] = useState("");
  const [preview, setPreview] = useState<RepetitionPreview | null>(null);
  const [notice, setNotice] = useState("");
  const [pendingConfirmation, setPendingConfirmation] = useState<{
    changeStart: boolean;
    previousSeriesId: string | null;
    startOn: string;
  } | null>(null);
  const [retryCommand, setRetryCommand] =
    useState<RepetitionCreateCommand | null>(null);
  const operationIdRef = useRef<string | null>(null);

  useEffect(() => {
    let active = true;
    const pending = operations.get(task.id);
    const initialStartOn = pending?.start_on ?? task.due_on ?? boardToday;
    setIsLoading(true);
    setShowSetup(pending !== null);
    setStartOn(initialStartOn);
    setFrequency(pending?.pattern.frequency ?? "daily");
    setInterval(String(pending?.pattern.interval ?? 1));
    setCalendarMode(
      pending?.pattern && "ordinal" in pending.pattern ? "ordinal" : "day",
    );
    setDayOfMonth(
      pending?.pattern && "day_of_month" in pending.pattern
        ? String(pending.pattern.day_of_month)
        : String(Number(initialStartOn.slice(8, 10))),
    );
    setMonth(
      pending?.pattern && "month" in pending.pattern
        ? String(pending.pattern.month)
        : String(Number(initialStartOn.slice(5, 7))),
    );
    setOrdinal(
      pending?.pattern && "ordinal" in pending.pattern
        ? String(pending.pattern.ordinal)
        : "1",
    );
    setOrdinalWeekday(
      pending?.pattern && "weekday" in pending.pattern
        ? String(pending.pattern.weekday)
        : String(isoWeekday(initialStartOn)),
    );
    setWeekdays(
      pending?.pattern.frequency === "weekly"
        ? [...pending.pattern.weekdays]
        : [isoWeekday(initialStartOn)],
    );
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

  function selectedPattern(): RepetitionPattern | null {
    return createRepetitionPattern({
      frequency,
      interval,
      weekdays,
      calendarMode,
      dayOfMonth,
      month,
      ordinal,
      weekday: ordinalWeekday,
    });
  }

  async function loadPreview() {
    if (!isOnline || isDisabled || hasUnsavedChanges) return;
    if (!startOn) {
      setNotice("Elige una primera fecha para preparar la repetición.");
      return;
    }
    const pattern = selectedPattern();
    if (!pattern) {
      setNotice(
        frequency === "weekly" && weekdays.length === 0
          ? "Elige al menos un día de la semana."
          : "El intervalo debe ser un número entero positivo válido.",
      );
      return;
    }
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
        pattern,
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
  ): RepetitionCreateCommand | null {
    const final = finalSelection();
    const pattern = selectedPattern();
    if (!final || !pattern) return null;
    operationIdRef.current ??= generateUUID();
    return {
      operation_id: operationIdRef.current,
      slug,
      task_id: task.id,
      start_on: startOn,
      end_on: final.endOn,
      occurrence_limit: final.occurrenceLimit,
      pattern,
      expected_due_on_version: task.field_versions.due_on,
      confirm_start_change: confirmStartChange,
      previous_series_id: previousSeriesId,
    };
  }

  async function submitCreate(command: RepetitionCreateCommand) {
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
        setNotice("La repetición quedó guardada.");
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
      if (error instanceof RepetitionError && error.reason === "rejected") {
        setNotice(
          "No se guardó la repetición. Revisa las fechas y vuelve a preparar la vista previa.",
        );
        setRetryCommand(null);
        operations.clear(task.id);
        operationIdRef.current = null;
      } else if (
        error instanceof RepetitionError &&
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
      aria-labelledby="task-repetition-heading"
    >
      <h3
        id="task-repetition-heading"
        className="mb-2 flex items-center gap-2 font-semibold text-sm text-text-primary"
      >
        <IconRepeat size={16} aria-hidden="true" /> Repetición
      </h3>
      {isLoading ? (
        <p className="text-text-muted text-xs" aria-live="polite">
          Consultando el estado de la serie…
        </p>
      ) : activeSeries && status?.status === "available" ? (
        <div className="space-y-3 text-sm">
          <p className="text-text-secondary">
            {patternLabel(status.pattern) ?? "Serie activa"} · próxima fecha:{" "}
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
              Programar repetición
            </Button>
          ) : (
            <div className="space-y-4 rounded-md border border-border p-3">
              <div
                className={
                  frequency === "weekly"
                    ? "grid gap-3 sm:grid-cols-2"
                    : "grid gap-3"
                }
              >
                <label
                  className="flex flex-col gap-1.5 font-semibold text-text-muted text-xs"
                  htmlFor="repetition-start"
                >
                  Primera fecha · zona {boardTimeZone}
                  <input
                    id="repetition-start"
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
                  htmlFor="repetition-final-mode"
                >
                  Final de la serie
                  <select
                    id="repetition-final-mode"
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
              <div className="grid gap-3 sm:grid-cols-2">
                <label
                  className="flex flex-col gap-1.5 font-semibold text-text-muted text-xs"
                  htmlFor="repetition-frequency"
                >
                  Frecuencia
                  <select
                    id="repetition-frequency"
                    value={frequency}
                    disabled={isWorking || Boolean(retryCommand)}
                    onChange={(event) => {
                      setFrequency(event.target.value as RepetitionFrequency);
                      setPreview(null);
                      setNotice("");
                    }}
                    className="h-10 rounded-md border border-border bg-surface-base px-3 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
                  >
                    <option value="daily">Diaria</option>
                    <option value="weekly">Semanal</option>
                    <option value="monthly">Mensual</option>
                    <option value="yearly">Anual</option>
                  </select>
                </label>
                {frequency !== "daily" ? (
                  <label
                    className="flex flex-col gap-1.5 font-semibold text-text-muted text-xs"
                    htmlFor="repetition-interval"
                  >
                    Repetir cada ·{" "}
                    {frequency === "weekly"
                      ? "semanas"
                      : frequency === "monthly"
                        ? "meses"
                        : "años"}
                    <input
                      id="repetition-interval"
                      type="number"
                      min={1}
                      max={frequency === "weekly" ? 2147483647 : undefined}
                      step={1}
                      value={interval}
                      disabled={isWorking || Boolean(retryCommand)}
                      onChange={(event) => {
                        setInterval(event.target.value);
                        setPreview(null);
                        setNotice("");
                      }}
                      className="h-10 rounded-md border border-border bg-transparent px-3 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
                    />
                  </label>
                ) : null}
              </div>
              {frequency === "monthly" || frequency === "yearly" ? (
                <div className="grid gap-3 sm:grid-cols-2">
                  {frequency === "yearly" ? (
                    <label
                      className="flex flex-col gap-1.5 font-semibold text-text-muted text-xs"
                      htmlFor="repetition-month"
                    >
                      Mes
                      <select
                        id="repetition-month"
                        value={month}
                        disabled={isWorking || Boolean(retryCommand)}
                        onChange={(event) => {
                          setMonth(event.target.value);
                          setPreview(null);
                          setNotice("");
                        }}
                        className="h-10 rounded-md border border-border bg-surface-base px-3 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
                      >
                        {MONTHS.map((monthName, index) => (
                          <option key={monthName} value={index + 1}>
                            {monthName}
                          </option>
                        ))}
                      </select>
                    </label>
                  ) : null}
                  <label
                    className="flex flex-col gap-1.5 font-semibold text-text-muted text-xs"
                    htmlFor="repetition-calendar-mode"
                  >
                    Regla del calendario
                    <select
                      id="repetition-calendar-mode"
                      value={calendarMode}
                      disabled={isWorking || Boolean(retryCommand)}
                      onChange={(event) => {
                        setCalendarMode(
                          event.target.value as "day" | "ordinal",
                        );
                        setPreview(null);
                        setNotice("");
                      }}
                      className="h-10 rounded-md border border-border bg-surface-base px-3 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
                    >
                      <option value="day">Día del mes</option>
                      <option value="ordinal">Ordinal de la semana</option>
                    </select>
                  </label>
                  {calendarMode === "day" ? (
                    <label
                      className="flex flex-col gap-1.5 font-semibold text-text-muted text-xs"
                      htmlFor="repetition-day-of-month"
                    >
                      Día del mes · del 1 al 31
                      <select
                        id="repetition-day-of-month"
                        value={dayOfMonth}
                        disabled={isWorking || Boolean(retryCommand)}
                        onChange={(event) => {
                          setDayOfMonth(event.target.value);
                          setPreview(null);
                          setNotice("");
                        }}
                        className="h-10 rounded-md border border-border bg-surface-base px-3 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
                      >
                        {Array.from(
                          { length: 31 },
                          (_, index) => index + 1,
                        ).map((day) => (
                          <option key={day} value={day}>
                            {day}
                          </option>
                        ))}
                        <option value={-1}>Último día</option>
                      </select>
                    </label>
                  ) : (
                    <>
                      <label
                        className="flex flex-col gap-1.5 font-semibold text-text-muted text-xs"
                        htmlFor="repetition-ordinal"
                      >
                        Ordinal
                        <select
                          id="repetition-ordinal"
                          value={ordinal}
                          disabled={isWorking || Boolean(retryCommand)}
                          onChange={(event) => {
                            setOrdinal(event.target.value);
                            setPreview(null);
                            setNotice("");
                          }}
                          className="h-10 rounded-md border border-border bg-surface-base px-3 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
                        >
                          {ORDINALS.map((item) => (
                            <option key={item.value} value={item.value}>
                              {item.label}
                            </option>
                          ))}
                        </select>
                      </label>
                      <label
                        className="flex flex-col gap-1.5 font-semibold text-text-muted text-xs"
                        htmlFor="repetition-ordinal-weekday"
                      >
                        Día de la semana
                        <select
                          id="repetition-ordinal-weekday"
                          value={ordinalWeekday}
                          disabled={isWorking || Boolean(retryCommand)}
                          onChange={(event) => {
                            setOrdinalWeekday(event.target.value);
                            setPreview(null);
                            setNotice("");
                          }}
                          className="h-10 rounded-md border border-border bg-surface-base px-3 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
                        >
                          {WEEKDAYS.map((day) => (
                            <option key={day.value} value={day.value}>
                              {day.label}
                            </option>
                          ))}
                        </select>
                      </label>
                    </>
                  )}
                </div>
              ) : null}
              {frequency === "weekly" ? (
                <fieldset
                  className="space-y-2 rounded-md border border-border p-3"
                  disabled={isWorking || Boolean(retryCommand)}
                >
                  <legend className="px-1 font-semibold text-text-muted text-xs">
                    Días de la semana · de lunes a domingo
                  </legend>
                  <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
                    {WEEKDAYS.map((day) => (
                      <label
                        key={day.value}
                        className="flex min-h-9 items-center gap-2 rounded-md px-2 text-sm text-text-primary hover:bg-surface-base"
                      >
                        <input
                          type="checkbox"
                          checked={weekdays.includes(day.value)}
                          onChange={(event) => {
                            setWeekdays((current) =>
                              event.target.checked
                                ? [...current, day.value].sort(
                                    (left, right) => left - right,
                                  )
                                : current.filter(
                                    (value) => value !== day.value,
                                  ),
                            );
                            setPreview(null);
                            setNotice("");
                          }}
                          className="size-4 accent-accent"
                        />
                        {day.label}
                      </label>
                    ))}
                  </div>
                  <div className="flex flex-wrap items-center gap-2">
                    <button
                      type="button"
                      onClick={() => {
                        setWeekdays([1, 2, 3, 4, 5]);
                        setPreview(null);
                        setNotice("");
                      }}
                      className="min-h-9 rounded-md border border-border px-3 font-semibold text-text-secondary text-xs hover:bg-surface-base focus-visible:outline-2 focus-visible:outline-accent"
                    >
                      Laborables (lunes a viernes)
                    </button>
                    <p className="text-text-muted text-xs">
                      Laborables no excluye feriados.
                    </p>
                  </div>
                </fieldset>
              ) : null}
              {finalMode === "count" ? (
                <label
                  className="flex max-w-xs flex-col gap-1.5 font-semibold text-text-muted text-xs"
                  htmlFor="repetition-count"
                >
                  Ocurrencias totales · esta tarea cuenta como la primera
                  <input
                    id="repetition-count"
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
                  htmlFor="repetition-end"
                >
                  Última fecha, inclusive
                  <input
                    id="repetition-end"
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
                    {patternLabel(preview.pattern) ??
                      patternLabel(selectedPattern() ?? undefined)}
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
                      ? " La serie conserva su fase del calendario aunque una ejecución se procese tarde."
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
                    Programar repetición
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
