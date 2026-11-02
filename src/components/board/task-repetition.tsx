"use client";

import { IconRepeat } from "@tabler/icons-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Modal } from "@/components/ui/modal";
import type { RepetitionEditOperationStore } from "@/lib/daily-repetition-edit-state";
import type { RepetitionOperationStore } from "@/lib/daily-repetition-state";
import type {
  RepetitionCreateCommand,
  RepetitionCreateResult,
  RepetitionEditCommand,
  RepetitionEditPreview,
  RepetitionEditResult,
  RepetitionFinalMode,
  RepetitionPattern,
  RepetitionPreview,
  RepetitionSeriesTemplate,
  RepetitionStatus,
} from "@/lib/db/daily-repetition";
import { RepetitionError } from "@/lib/db/daily-repetition";
import {
  createRepetitionPattern,
  REPETITION_MONTHS as MONTHS,
  repetitionPatternSummary as patternLabel,
  REPETITION_WEEKDAYS as WEEKDAYS,
} from "@/lib/repetition-pattern";
import { formatTaskDueDate } from "@/lib/task-date";
import type {
  AssignableBoardMember,
  ColumnWithTasks,
  Priority,
  Task,
} from "@/lib/types";
import { generateUUID } from "@/lib/utils";

interface TaskRepetitionProps {
  task: Task;
  slug: string;
  boardToday: string;
  boardTimeZone: string;
  isOnline: boolean;
  isDisabled: boolean;
  openEditorOnLoad: boolean;
  hasUnsavedChanges: boolean;
  operations: RepetitionOperationStore;
  editOperations: RepetitionEditOperationStore;
  columns: ColumnWithTasks[];
  assignableMembers: AssignableBoardMember[] | null;
  onLoad: (taskId: string) => Promise<RepetitionStatus>;
  onPreview: (
    taskId: string,
    startOn: string,
    endOn: string | null,
    occurrenceLimit: number | null,
    pattern: RepetitionPattern,
    advanceDays: number,
  ) => Promise<RepetitionPreview>;
  onCreate: (
    command: RepetitionCreateCommand,
  ) => Promise<RepetitionCreateResult>;
  onPreviewEdit: (
    command: Omit<RepetitionEditCommand, "operation_id" | "expected_revision">,
  ) => Promise<RepetitionEditPreview>;
  onEdit: (command: RepetitionEditCommand) => Promise<RepetitionEditResult>;
}

type FinalMode = RepetitionFinalMode;
type RepetitionFrequency = RepetitionPattern["frequency"];
interface RepetitionTemplateStepDraft {
  id: string;
  text: string;
}

function templateStepDrafts(
  steps: RepetitionSeriesTemplate["steps"] | undefined,
): RepetitionTemplateStepDraft[] {
  return (steps ?? []).map((step) => ({
    id: generateUUID(),
    text: step.text,
  }));
}

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
  openEditorOnLoad,
  hasUnsavedChanges,
  operations,
  editOperations,
  columns,
  assignableMembers,
  onLoad,
  onPreview,
  onCreate,
  onPreviewEdit,
  onEdit,
}: TaskRepetitionProps) {
  const [status, setStatus] = useState<RepetitionStatus | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isWorking, setIsWorking] = useState(false);
  const [showSetup, setShowSetup] = useState(false);
  const [editingSeries, setEditingSeries] = useState(false);
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
  const [advanceDays, setAdvanceDays] = useState("0");
  const [appearanceColumnId, setAppearanceColumnId] = useState(task.column_id);
  const [templateTitle, setTemplateTitle] = useState(task.title);
  const [templateDescription, setTemplateDescription] = useState(
    task.description ?? "",
  );
  const [templatePriority, setTemplatePriority] = useState<Priority>(
    task.priority,
  );
  const [templateAssigneeId, setTemplateAssigneeId] = useState(
    task.assignee_id ?? "",
  );
  const [templateSteps, setTemplateSteps] = useState<
    RepetitionTemplateStepDraft[]
  >([]);
  const [preview, setPreview] = useState<RepetitionPreview | null>(null);
  const [editPreview, setEditPreview] = useState<RepetitionEditPreview | null>(
    null,
  );
  const [confirmDateChoice, setConfirmDateChoice] = useState(false);
  const [notice, setNotice] = useState("");
  const [pendingConfirmation, setPendingConfirmation] = useState<{
    changeStart: boolean;
    previousSeriesId: string | null;
    startOn: string;
  } | null>(null);
  const [retryCommand, setRetryCommand] =
    useState<RepetitionCreateCommand | null>(null);
  const [retryEditCommand, setRetryEditCommand] =
    useState<RepetitionEditCommand | null>(null);
  const operationIdRef = useRef<string | null>(null);
  const editOperationIdRef = useRef<string | null>(null);

  const applyPattern = useCallback(
    (pattern: RepetitionPattern, anchor: string) => {
      setFrequency(pattern.frequency);
      setInterval(String(pattern.interval));
      setCalendarMode("ordinal" in pattern ? "ordinal" : "day");
      setDayOfMonth(
        "day_of_month" in pattern
          ? String(pattern.day_of_month)
          : String(Number(anchor.slice(8, 10))),
      );
      setMonth(
        "month" in pattern
          ? String(pattern.month)
          : String(Number(anchor.slice(5, 7))),
      );
      setOrdinal("ordinal" in pattern ? String(pattern.ordinal) : "1");
      setOrdinalWeekday(
        "weekday" in pattern
          ? String(pattern.weekday)
          : String(isoWeekday(anchor)),
      );
      setWeekdays(
        pattern.frequency === "weekly"
          ? [...pattern.weekdays]
          : [isoWeekday(anchor)],
      );
    },
    [],
  );

  const clearPreview = useCallback(() => {
    setPreview(null);
    setEditPreview(null);
    setConfirmDateChoice(false);
  }, []);

  useEffect(() => {
    let active = true;
    const pending = operations.get(task.id);
    const pendingEdit = editOperations.get(task.id);
    const initialStartOn =
      pendingEdit?.start_on ?? pending?.start_on ?? task.due_on ?? boardToday;
    setIsLoading(true);
    setShowSetup(pending !== null || pendingEdit !== null);
    setEditingSeries(pendingEdit !== null);
    setStartOn(initialStartOn);
    const pendingPattern = pendingEdit?.pattern ?? pending?.pattern;
    if (pendingPattern) applyPattern(pendingPattern, initialStartOn);
    else applyPattern({ frequency: "daily", interval: 1 }, initialStartOn);
    setAdvanceDays(
      String(pendingEdit?.advance_days ?? pending?.advance_days ?? 0),
    );
    setAppearanceColumnId(
      pendingEdit?.appearance_column_id ??
        pending?.appearance_column_id ??
        task.column_id,
    );
    const pendingTemplate = pendingEdit?.template;
    setTemplateTitle(pendingTemplate?.title ?? task.title);
    setTemplateDescription(
      pendingTemplate?.description ?? task.description ?? "",
    );
    setTemplatePriority(pendingTemplate?.priority ?? task.priority);
    setTemplateAssigneeId(
      pendingTemplate?.assignee_id ?? task.assignee_id ?? "",
    );
    setTemplateSteps(templateStepDrafts(pendingTemplate?.steps));
    const initialFinalMode =
      pendingEdit?.final_mode ??
      (pending?.end_on
        ? "date"
        : pending?.occurrence_limit === null
          ? "none"
          : "count");
    setFinalMode(initialFinalMode);
    setOccurrenceCount(
      String(pendingEdit?.future_count ?? pending?.occurrence_limit ?? 3),
    );
    setEndOn(pendingEdit?.end_on ?? pending?.end_on ?? "");
    clearPreview();
    setNotice(
      pending || pendingEdit
        ? "Hay una operación pendiente de confirmación. Reintenta la misma solicitud para revisar su resultado."
        : "",
    );
    setPendingConfirmation(null);
    setRetryCommand(pending);
    setRetryEditCommand(pendingEdit);
    operationIdRef.current = pending?.operation_id ?? null;
    editOperationIdRef.current = pendingEdit?.operation_id ?? null;
    void onLoad(task.id)
      .then((result) => {
        if (!active) return;
        setStatus(result);
        if (
          !pendingEdit &&
          result.status === "available" &&
          result.state === "active"
        ) {
          const nextStart = result.next_due_on ?? initialStartOn;
          setStartOn(nextStart);
          if (result.pattern) applyPattern(result.pattern, nextStart);
          setAdvanceDays(String(result.advance_days ?? 0));
          setAppearanceColumnId(result.appearance_column_id ?? task.column_id);
          setTemplateTitle(result.template_snapshot?.title ?? task.title);
          setTemplateDescription(
            result.template_snapshot?.description ?? task.description ?? "",
          );
          setTemplatePriority(
            result.template_snapshot?.priority ?? task.priority,
          );
          setTemplateAssigneeId(
            result.template_snapshot?.assignee_id ?? task.assignee_id ?? "",
          );
          setTemplateSteps(templateStepDrafts(result.template_snapshot?.steps));
          if (result.end_on) {
            setFinalMode("date");
            setEndOn(result.end_on);
          } else if (result.occurrence_limit === null) {
            setFinalMode("none");
            setEndOn("");
          } else {
            setFinalMode("count");
            setOccurrenceCount(
              String(
                Math.max(
                  1,
                  (result.occurrence_limit ?? 1) - (result.consumed_count ?? 1),
                ),
              ),
            );
          }
        }
        if (
          openEditorOnLoad &&
          result.status === "available" &&
          result.state === "active" &&
          typeof result.revision === "number" &&
          result.template_snapshot
        ) {
          setEditingSeries(true);
          setShowSetup(true);
        }
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
  }, [
    onLoad,
    applyPattern,
    clearPreview,
    operations,
    editOperations,
    task.assignee_id,
    task.column_id,
    task.description,
    task.due_on,
    task.id,
    task.priority,
    task.title,
    boardToday,
    openEditorOnLoad,
  ]);

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

  function selectedAdvanceDays(): number | null {
    const value = Number(advanceDays);
    return Number.isSafeInteger(value) && value >= 0 ? value : null;
  }

  function editPreviewCommand(
    confirmChoice: boolean,
    startOverride?: string,
  ): Omit<RepetitionEditCommand, "operation_id" | "expected_revision"> | null {
    const final = finalSelection();
    const pattern = selectedPattern();
    const advance = selectedAdvanceDays();
    if (!final || !pattern || advance === null || !appearanceColumnId) {
      return null;
    }
    const template: RepetitionSeriesTemplate = {
      title: templateTitle.trim(),
      description: templateDescription.trim() || null,
      priority: templatePriority,
      assignee_id: templateAssigneeId || null,
      steps: templateSteps.flatMap((step, index) => {
        const text = step.text.trim();
        return text ? [{ text, position: index }] : [];
      }),
    };
    return {
      slug,
      task_id: task.id,
      start_on: startOverride ?? startOn,
      final_mode: finalMode,
      future_count: finalMode === "count" ? final.occurrenceLimit : null,
      end_on: finalMode === "date" ? final.endOn : null,
      pattern,
      advance_days: advance,
      appearance_column_id: appearanceColumnId,
      template,
      confirm_date_choice: confirmChoice,
    };
  }

  async function loadEditPreview(
    confirmChoice = confirmDateChoice,
    startOverride?: string,
  ) {
    if (!isOnline || isDisabled) return;
    if (!startOverride && !startOn) {
      setNotice("Elige la primera fecha futura para preparar los cambios.");
      return;
    }
    const command = editPreviewCommand(confirmChoice, startOverride);
    if (!command) {
      setNotice(
        selectedAdvanceDays() === null
          ? "La anticipación debe ser un número entero igual o mayor que cero."
          : "Revisa la cantidad próxima, la fecha final y los datos de plantilla.",
      );
      return;
    }
    setIsWorking(true);
    setNotice("");
    clearPreview();
    setEditPreview(null);
    try {
      const nextPreview = await onPreviewEdit(command);
      if (nextPreview.status !== "available") {
        setNotice("La serie ya no está disponible para editar.");
        return;
      }
      setEditPreview(nextPreview);
      if (nextPreview.requires_date_choice) {
        setNotice(
          "La fecha elegida no coincide con la regla nueva. Confirma esa fecha o elige la fecha sugerida.",
        );
      } else if (nextPreview.appearance_compatible === false) {
        setNotice(
          nextPreview.appearance_conflict_message ??
            "La primera aparición debe ser posterior al vencimiento actual. Elige una fecha inicial posterior o reduce la anticipación.",
        );
      }
    } catch (error) {
      setNotice(
        error instanceof RepetitionError && error.reason === "rejected"
          ? "La anticipación debe ser menor que la separación mínima entre fechas de la serie."
          : "No se pudo generar la vista previa. La serie y el borrador siguen intactos.",
      );
    } finally {
      setIsWorking(false);
    }
  }

  async function loadPreview() {
    if (!isOnline || isDisabled) return;
    if (editingSeries) {
      await loadEditPreview();
      return;
    }
    if (hasUnsavedChanges) return;
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
    const advance = selectedAdvanceDays();
    if (advance === null) {
      setNotice(
        "La anticipación debe ser un número entero igual o mayor que cero.",
      );
      return;
    }
    setIsWorking(true);
    setNotice("");
    clearPreview();
    try {
      const nextPreview = await onPreview(
        task.id,
        startOn,
        final.endOn,
        final.occurrenceLimit,
        pattern,
        advance,
      );
      if (nextPreview.status !== "available") {
        setNotice(
          "No se pudo consultar esta tarea para preparar la repetición.",
        );
        return;
      }
      setPreview(nextPreview);
      if (nextPreview.appearance_compatible === false) {
        setNotice(
          nextPreview.appearance_conflict_message ??
            "La primera aparición debe ser posterior al vencimiento actual. Elige una fecha inicial posterior o reduce la anticipación.",
        );
      }
    } catch (error) {
      setNotice(
        error instanceof RepetitionError && error.reason === "rejected"
          ? "La anticipación debe ser menor que la separación mínima entre fechas de la serie."
          : "No se pudo generar la vista previa. Los datos de la tarea no cambiaron.",
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
      advance_days: selectedAdvanceDays() ?? 0,
      appearance_column_id: appearanceColumnId,
      expected_due_on_version: task.field_versions.due_on,
      confirm_start_change: confirmStartChange,
      previous_series_id: previousSeriesId,
    };
  }

  function editCommandFor(): RepetitionEditCommand | null {
    if (
      !editPreview ||
      editPreview.status !== "available" ||
      editPreview.requires_date_choice ||
      editPreview.appearance_compatible !== true ||
      typeof editPreview.series_revision !== "number"
    ) {
      return null;
    }
    const draft = editPreviewCommand(confirmDateChoice);
    if (!draft) return null;
    editOperationIdRef.current ??= generateUUID();
    return {
      ...draft,
      operation_id: editOperationIdRef.current,
      expected_revision: editPreview.series_revision,
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
        clearPreview();
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
      if (result.status === "appearance_conflict") {
        operationIdRef.current = null;
        setNotice(
          result.appearance_conflict_message ??
            "La primera aparición debe ser posterior al vencimiento actual. Elige una fecha inicial posterior o reduce la anticipación.",
        );
        return;
      }
      if (result.status === "conflict") {
        operationIdRef.current = null;
        setNotice(
          "La tarea o la serie cambió mientras preparabas la repetición. Actualiza la vista previa y revisa el estado actual.",
        );
        clearPreview();
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
    if (preview.appearance_compatible !== true) return;
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

  async function submitEdit(command: RepetitionEditCommand) {
    setIsWorking(true);
    setNotice("");
    try {
      const result = await onEdit(command);
      setRetryEditCommand(null);
      editOperations.clear(task.id);
      if (result.status === "confirmed") {
        editOperationIdRef.current = null;
        setEditingSeries(false);
        setShowSetup(false);
        clearPreview();
        setNotice("Las próximas repeticiones quedaron actualizadas.");
        setStatus(await onLoad(task.id));
        return;
      }
      if (result.status === "date_choice_required") {
        setEditPreview({
          ...result,
          status: "available",
          requires_date_choice: true,
        });
        setConfirmDateChoice(false);
        setNotice(
          "Confirma la primera fecha futura para que coincida con la nueva regla.",
        );
        return;
      }
      if (result.status === "appearance_conflict") {
        editOperationIdRef.current = null;
        setEditPreview({
          ...result,
          status: "available",
          appearance_compatible: false,
        });
        setNotice(
          result.appearance_conflict_message ??
            "La primera aparición debe ser posterior al vencimiento actual. Elige una fecha inicial posterior o reduce la anticipación.",
        );
        return;
      }
      if (result.status === "conflict") {
        editOperationIdRef.current = null;
        clearPreview();
        setNotice(
          "La serie cambió mientras editabas. El borrador se conserva; actualiza la vista previa para revisar el estado actual.",
        );
        setStatus(await onLoad(task.id));
        return;
      }
      editOperationIdRef.current = null;
      setNotice(
        result.status === "expired_unknown"
          ? "No se pudo confirmar el resultado anterior. Revisa la serie antes de volver a editarla."
          : "La serie ya no está disponible para editar.",
      );
      setStatus(await onLoad(task.id));
    } catch (error) {
      if (error instanceof RepetitionError && error.reason === "rejected") {
        setNotice(
          "No se guardaron los cambios. Revisa la fecha, la anticipación y la plantilla; el borrador se conserva.",
        );
        setRetryEditCommand(null);
        editOperations.clear(task.id);
        editOperationIdRef.current = null;
      } else if (
        error instanceof RepetitionError &&
        error.reason === "access_denied"
      ) {
        setNotice(
          "Tu acceso al tablero cambió. Actualiza la página antes de continuar.",
        );
        editOperations.clear(task.id);
      } else {
        editOperations.set(command);
        setRetryEditCommand(command);
        setNotice(
          "No se pudo confirmar el resultado. Reintenta la misma edición para evitar duplicados.",
        );
      }
    } finally {
      setIsWorking(false);
    }
  }

  async function saveEdit() {
    if (!isOnline || isDisabled || !editPreview) return;
    const command = editCommandFor();
    if (!command) return;
    await submitEdit(command);
  }

  async function retryEdit() {
    if (!retryEditCommand || isWorking) return;
    await submitEdit(retryEditCommand);
  }

  function chooseSuggestedDate() {
    const suggested = editPreview?.proposed_start_on;
    if (!suggested) return;
    setStartOn(suggested);
    setConfirmDateChoice(false);
    void loadEditPreview(false, suggested);
  }

  function beginCreate() {
    setEditingSeries(false);
    setShowSetup(true);
    setNotice("");
    clearPreview();
  }

  function moveTemplateStep(index: number, offset: number) {
    const target = index + offset;
    setTemplateSteps((current) => {
      if (target < 0 || target >= current.length) return current;
      const next = [...current];
      const [step] = next.splice(index, 1);
      next.splice(target, 0, step);
      return next;
    });
    clearPreview();
  }

  function beginEdit(candidate: RepetitionStatus | null = status) {
    if (
      candidate?.status !== "available" ||
      candidate.state !== "active" ||
      typeof candidate.revision !== "number" ||
      !candidate.template_snapshot
    ) {
      return;
    }
    const nextStart = candidate.next_due_on ?? task.due_on ?? boardToday;
    setEditingSeries(true);
    setShowSetup(true);
    setStartOn(nextStart);
    if (candidate.pattern) applyPattern(candidate.pattern, nextStart);
    setAdvanceDays(String(candidate.advance_days ?? 0));
    setAppearanceColumnId(candidate.appearance_column_id ?? task.column_id);
    setTemplateTitle(candidate.template_snapshot.title ?? task.title);
    setTemplateDescription(
      candidate.template_snapshot.description ?? task.description ?? "",
    );
    setTemplatePriority(candidate.template_snapshot.priority ?? task.priority);
    setTemplateAssigneeId(
      candidate.template_snapshot.assignee_id ?? task.assignee_id ?? "",
    );
    setTemplateSteps(templateStepDrafts(candidate.template_snapshot.steps));
    if (candidate.end_on) {
      setFinalMode("date");
      setEndOn(candidate.end_on);
    } else if (candidate.occurrence_limit === null) {
      setFinalMode("none");
      setEndOn("");
    } else {
      setFinalMode("count");
      setOccurrenceCount(
        String(
          Math.max(
            1,
            (candidate.occurrence_limit ?? 1) - (candidate.consumed_count ?? 1),
          ),
        ),
      );
    }
    setRetryEditCommand(null);
    editOperationIdRef.current = null;
    setNotice("");
    clearPreview();
  }

  const activeSeries =
    status?.status === "available" && status.state === "active";
  const canCreate =
    status?.status === "not_repeating" ||
    (status?.status === "available" && status.state !== "active");
  const canEdit =
    activeSeries &&
    status?.status === "available" &&
    typeof status.revision === "number" &&
    Boolean(status.template_snapshot);

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
      ) : activeSeries && status?.status === "available" && !showSetup ? (
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
          <Button
            type="button"
            variant="ghost"
            onClick={() => beginEdit()}
            disabled={
              !canEdit ||
              isDisabled ||
              isWorking ||
              !isOnline ||
              hasUnsavedChanges
            }
          >
            Editar próximas repeticiones
          </Button>
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
          {status?.status === "available" && !editingSeries ? (
            <p className="text-sm text-text-secondary">
              Serie {stateLabel(status.state ?? "")}. El historial se conserva
              al programar una nueva serie.
            </p>
          ) : null}
          {hasUnsavedChanges && !editingSeries ? (
            <p className="text-text-muted text-xs">
              Guarda primero los cambios de esta tarjeta para convertirla en la
              primera ocurrencia.
            </p>
          ) : null}
          {!showSetup ? (
            <Button
              type="button"
              variant="ghost"
              onClick={beginCreate}
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
                  {editingSeries ? "Próxima fecha futura" : "Primera fecha"} ·
                  zona {boardTimeZone}
                  <input
                    id="repetition-start"
                    type="date"
                    value={startOn}
                    disabled={
                      isWorking || Boolean(retryCommand || retryEditCommand)
                    }
                    onChange={(event) => {
                      setStartOn(event.target.value);
                      clearPreview();
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
                    disabled={
                      isWorking || Boolean(retryCommand || retryEditCommand)
                    }
                    onChange={(event) => {
                      setFinalMode(event.target.value as FinalMode);
                      clearPreview();
                    }}
                    className="h-10 rounded-md border border-border bg-surface-base px-3 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
                  >
                    <option value="count">
                      {editingSeries
                        ? "Cantidad de próximas repeticiones"
                        : "Cantidad total incluyendo esta tarea"}
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
                  htmlFor="repetition-advance-days"
                >
                  Anticipar próxima tarjeta · días
                  <input
                    id="repetition-advance-days"
                    type="number"
                    min={0}
                    step={1}
                    value={advanceDays}
                    disabled={
                      isWorking || Boolean(retryCommand || retryEditCommand)
                    }
                    onChange={(event) => {
                      setAdvanceDays(event.target.value);
                      clearPreview();
                    }}
                    className="h-10 rounded-md border border-border bg-transparent px-3 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
                  />
                  <span className="font-normal text-text-muted">
                    Debe ser menor que la separación mínima entre fechas.
                  </span>
                </label>
                <label
                  className="flex flex-col gap-1.5 font-semibold text-text-muted text-xs"
                  htmlFor="repetition-appearance-column"
                >
                  Columna de las próximas tarjetas
                  <select
                    id="repetition-appearance-column"
                    value={appearanceColumnId}
                    disabled={
                      isWorking || Boolean(retryCommand || retryEditCommand)
                    }
                    onChange={(event) => {
                      setAppearanceColumnId(event.target.value);
                      clearPreview();
                    }}
                    className="h-10 rounded-md border border-border bg-surface-base px-3 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
                  >
                    {columns.map((column) => (
                      <option key={column.id} value={column.id}>
                        {column.title}
                      </option>
                    ))}
                  </select>
                </label>
              </div>
              {editingSeries ? (
                <fieldset
                  className="space-y-3 rounded-md border border-border p-3"
                  disabled={isWorking || Boolean(retryEditCommand)}
                >
                  <legend className="px-1 font-semibold text-text-muted text-xs">
                    Plantilla de las próximas tarjetas
                  </legend>
                  <label
                    className="flex flex-col gap-1.5 font-semibold text-text-muted text-xs"
                    htmlFor="repetition-template-title"
                  >
                    Título
                    <input
                      id="repetition-template-title"
                      type="text"
                      maxLength={200}
                      value={templateTitle}
                      onChange={(event) => {
                        setTemplateTitle(event.target.value);
                        clearPreview();
                      }}
                      className="h-10 rounded-md border border-border bg-transparent px-3 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
                    />
                  </label>
                  <label
                    className="flex flex-col gap-1.5 font-semibold text-text-muted text-xs"
                    htmlFor="repetition-template-description"
                  >
                    Descripción
                    <textarea
                      id="repetition-template-description"
                      maxLength={2000}
                      rows={3}
                      value={templateDescription}
                      onChange={(event) => {
                        setTemplateDescription(event.target.value);
                        clearPreview();
                      }}
                      className="rounded-md border border-border bg-transparent px-3 py-2 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
                    />
                  </label>
                  <div className="grid gap-3 sm:grid-cols-2">
                    <label
                      className="flex flex-col gap-1.5 font-semibold text-text-muted text-xs"
                      htmlFor="repetition-template-priority"
                    >
                      Prioridad
                      <select
                        id="repetition-template-priority"
                        value={templatePriority}
                        onChange={(event) => {
                          setTemplatePriority(event.target.value as Priority);
                          clearPreview();
                        }}
                        className="h-10 rounded-md border border-border bg-surface-base px-3 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
                      >
                        <option value="low">Baja</option>
                        <option value="medium">Media</option>
                        <option value="high">Alta</option>
                        <option value="urgent">Urgente</option>
                      </select>
                    </label>
                    <label
                      className="flex flex-col gap-1.5 font-semibold text-text-muted text-xs"
                      htmlFor="repetition-template-assignee"
                    >
                      Responsable
                      <select
                        id="repetition-template-assignee"
                        value={templateAssigneeId}
                        disabled={!assignableMembers}
                        onChange={(event) => {
                          setTemplateAssigneeId(event.target.value);
                          clearPreview();
                        }}
                        className="h-10 rounded-md border border-border bg-surface-base px-3 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
                      >
                        <option value="">Sin responsable</option>
                        {assignableMembers?.map((member) => (
                          <option key={member.user_id} value={member.user_id}>
                            {member.name}
                          </option>
                        ))}
                      </select>
                    </label>
                  </div>
                  <fieldset className="space-y-2 rounded-md border border-border p-3">
                    <legend className="px-1 font-semibold text-text-muted text-xs">
                      Checklist de las próximas tarjetas
                    </legend>
                    <p className="text-text-secondary text-xs">
                      Cada próxima tarjeta recibe estos pasos sin marcar. Los
                      pasos de la tarjeta actual permanecen independientes.
                    </p>
                    {templateSteps.map((step, index) => (
                      <div
                        key={step.id}
                        className="flex flex-wrap items-end gap-2"
                      >
                        <label
                          className="flex min-w-40 flex-1 flex-col gap-1.5 font-semibold text-text-muted text-xs"
                          htmlFor={`repetition-template-step-${index}`}
                        >
                          Paso {index + 1}
                          <input
                            id={`repetition-template-step-${index}`}
                            type="text"
                            value={step.text}
                            onChange={(event) => {
                              setTemplateSteps((current) =>
                                current.map((value) =>
                                  value.id === step.id
                                    ? { ...value, text: event.target.value }
                                    : value,
                                ),
                              );
                              clearPreview();
                            }}
                            className="h-10 rounded-md border border-border bg-transparent px-3 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
                          />
                        </label>
                        <Button
                          type="button"
                          variant="ghost"
                          aria-label={`Subir el paso ${index + 1}`}
                          disabled={index === 0}
                          onClick={() => moveTemplateStep(index, -1)}
                        >
                          ↑
                        </Button>
                        <Button
                          type="button"
                          variant="ghost"
                          aria-label={`Bajar el paso ${index + 1}`}
                          disabled={index === templateSteps.length - 1}
                          onClick={() => moveTemplateStep(index, 1)}
                        >
                          ↓
                        </Button>
                        <Button
                          type="button"
                          variant="ghost"
                          aria-label={`Quitar el paso ${index + 1}`}
                          onClick={() => {
                            setTemplateSteps((current) =>
                              current.filter((value) => value.id !== step.id),
                            );
                            clearPreview();
                          }}
                        >
                          Quitar
                        </Button>
                      </div>
                    ))}
                    <Button
                      type="button"
                      variant="ghost"
                      onClick={() => {
                        setTemplateSteps((current) => [
                          ...current,
                          { id: generateUUID(), text: "" },
                        ]);
                        clearPreview();
                      }}
                    >
                      Agregar paso
                    </Button>
                  </fieldset>
                </fieldset>
              ) : null}
              <div className="grid gap-3 sm:grid-cols-2">
                <label
                  className="flex flex-col gap-1.5 font-semibold text-text-muted text-xs"
                  htmlFor="repetition-frequency"
                >
                  Frecuencia
                  <select
                    id="repetition-frequency"
                    value={frequency}
                    disabled={
                      isWorking || Boolean(retryCommand || retryEditCommand)
                    }
                    onChange={(event) => {
                      setFrequency(event.target.value as RepetitionFrequency);
                      clearPreview();
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
                      disabled={
                        isWorking || Boolean(retryCommand || retryEditCommand)
                      }
                      onChange={(event) => {
                        setInterval(event.target.value);
                        clearPreview();
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
                        disabled={
                          isWorking || Boolean(retryCommand || retryEditCommand)
                        }
                        onChange={(event) => {
                          setMonth(event.target.value);
                          clearPreview();
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
                      disabled={
                        isWorking || Boolean(retryCommand || retryEditCommand)
                      }
                      onChange={(event) => {
                        setCalendarMode(
                          event.target.value as "day" | "ordinal",
                        );
                        clearPreview();
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
                        disabled={
                          isWorking || Boolean(retryCommand || retryEditCommand)
                        }
                        onChange={(event) => {
                          setDayOfMonth(event.target.value);
                          clearPreview();
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
                          disabled={
                            isWorking ||
                            Boolean(retryCommand || retryEditCommand)
                          }
                          onChange={(event) => {
                            setOrdinal(event.target.value);
                            clearPreview();
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
                          disabled={
                            isWorking ||
                            Boolean(retryCommand || retryEditCommand)
                          }
                          onChange={(event) => {
                            setOrdinalWeekday(event.target.value);
                            clearPreview();
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
                  disabled={
                    isWorking || Boolean(retryCommand || retryEditCommand)
                  }
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
                            clearPreview();
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
                        clearPreview();
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
                  {editingSeries
                    ? "Próximas repeticiones · la actual y las anteriores quedan fuera"
                    : "Ocurrencias totales · esta tarea cuenta como la primera"}
                  <input
                    id="repetition-count"
                    type="number"
                    min={1}
                    max={2147483648}
                    value={occurrenceCount}
                    disabled={
                      isWorking || Boolean(retryCommand || retryEditCommand)
                    }
                    onChange={(event) => {
                      setOccurrenceCount(event.target.value);
                      clearPreview();
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
                    disabled={
                      isWorking || Boolean(retryCommand || retryEditCommand)
                    }
                    onChange={(event) => {
                      setEndOn(event.target.value);
                      clearPreview();
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
                    Plantilla futura: {task.title} · {task.priority} · columna{" "}
                    {columns.find((column) => column.id === appearanceColumnId)
                      ?.title ?? "elegida"}
                    .
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
                  {preview.appearance_dates?.length ? (
                    <p className="mt-1 text-text-secondary">
                      Aparecen con {preview.advance_days ?? 0} días de
                      anticipación (separación mínima:{" "}
                      {preview.minimum_separation_days ?? "—"} días):{" "}
                      {preview.appearance_dates
                        .map((date) => formatTaskDueDate(date) ?? date)
                        .join(", ")}
                      .
                    </p>
                  ) : null}
                  {preview.appearance_compatible === false ? (
                    <p role="alert" className="mt-2 text-priority-medium">
                      La primera próxima tarea aparecería el{" "}
                      {formatTaskDueDate(preview.first_appearance_on ?? null) ??
                        preview.first_appearance_on ??
                        "—"}
                      , antes o el mismo día del vencimiento actual (
                      {formatTaskDueDate(preview.current_due_on ?? null) ??
                        preview.current_due_on ??
                        "—"}
                      ). Elige una fecha inicial posterior o reduce la
                      anticipación.
                    </p>
                  ) : null}
                  <p className="mt-1 text-text-secondary">
                    Zona del tablero: {preview.time_zone ?? boardTimeZone}.
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
              {editPreview ? (
                <div
                  className="space-y-1 rounded-md bg-surface-base p-3 text-sm"
                  aria-live="polite"
                >
                  <p className="font-medium text-text-primary">
                    La tarjeta actual conserva su fecha, identidad e historial:{" "}
                    {formatTaskDueDate(task.due_on) ?? task.due_on}.
                  </p>
                  <p className="text-text-secondary">
                    {patternLabel(editPreview.pattern) ??
                      patternLabel(selectedPattern() ?? undefined)}{" "}
                    · zona del tablero: {editPreview.time_zone ?? boardTimeZone}
                    .
                  </p>
                  <p className="text-text-secondary">
                    Plantilla:{" "}
                    {editPreview.template_snapshot?.title ?? templateTitle} ·{" "}
                    {editPreview.template_snapshot?.priority ??
                      templatePriority}{" "}
                    · columna{" "}
                    {columns.find(
                      (column) =>
                        column.id ===
                        (editPreview.appearance_column_id ??
                          appearanceColumnId),
                    )?.title ?? "elegida"}
                    .
                  </p>
                  <p className="text-text-secondary">
                    Responsable de futuras tarjetas:{" "}
                    {editPreview.template_snapshot?.assignee_id
                      ? (assignableMembers?.find(
                          (member) =>
                            member.user_id ===
                            editPreview.template_snapshot?.assignee_id,
                        )?.name ?? "no disponible en este tablero")
                      : "sin responsable"}
                    .
                  </p>
                  {editPreview.template_snapshot?.description ? (
                    <p className="whitespace-pre-wrap text-text-secondary">
                      {editPreview.template_snapshot.description}
                    </p>
                  ) : null}
                  <div className="text-text-secondary">
                    <p>Checklist de futuras tarjetas:</p>
                    {editPreview.template_snapshot?.steps?.length ? (
                      <ol
                        aria-label="Pasos de la checklist de futuras tarjetas"
                        className="list-inside list-decimal pl-2"
                      >
                        {editPreview.template_snapshot.steps.map(
                          (step, index) => (
                            <li key={`${step.position}-${index}`}>
                              {step.text}
                            </li>
                          ),
                        )}
                      </ol>
                    ) : (
                      <p>Sin pasos de checklist.</p>
                    )}
                  </div>
                  {editPreview.requires_date_choice ? (
                    <div className="space-y-2 rounded-md border border-priority-medium/40 p-3 text-text-secondary">
                      <p>
                        {editPreview.selected_date_compatible
                          ? `${startOn} cumple la nueva regla, pero cambia la próxima fecha sugerida. Confirma cuál fecha usar. La sugerida es ${editPreview.proposed_start_on ?? "—"}.`
                          : `${startOn} no cumple la nueva regla o ya quedó en el pasado. Elige una fecha compatible antes de guardar. La sugerida es ${editPreview.proposed_start_on ?? "—"}.`}
                      </p>
                      <div className="flex flex-wrap gap-2">
                        <Button
                          type="button"
                          variant="ghost"
                          onClick={chooseSuggestedDate}
                          disabled={isWorking || !isOnline}
                        >
                          Usar fecha sugerida
                        </Button>
                        {editPreview.selected_date_compatible ? (
                          <Button
                            type="button"
                            variant="ghost"
                            onClick={() => {
                              setConfirmDateChoice(true);
                              void loadEditPreview(true);
                            }}
                            disabled={isWorking || !isOnline}
                          >
                            Confirmar la fecha elegida
                          </Button>
                        ) : null}
                      </div>
                    </div>
                  ) : (
                    <>
                      <p className="text-text-secondary">
                        Próximas fechas:{" "}
                        {editPreview.future_dates?.length
                          ? editPreview.future_dates
                              .map((date) => formatTaskDueDate(date) ?? date)
                              .join(", ")
                          : "ninguna"}
                        .
                      </p>
                      <p className="text-text-secondary">
                        Aparecen {editPreview.advance_days ?? 0} días antes
                        (separación mínima:{" "}
                        {editPreview.minimum_separation_days ?? "—"} días):{" "}
                        {editPreview.appearance_dates?.length
                          ? editPreview.appearance_dates
                              .map((date) => formatTaskDueDate(date) ?? date)
                              .join(", ")
                          : "ninguna"}
                        .
                      </p>
                      {editPreview.appearance_compatible === false ? (
                        <p role="alert" className="text-priority-medium">
                          La primera próxima tarea aparecería el{" "}
                          {formatTaskDueDate(
                            editPreview.first_appearance_on ?? null,
                          ) ??
                            editPreview.first_appearance_on ??
                            "—"}
                          , antes o el mismo día del vencimiento actual (
                          {formatTaskDueDate(
                            editPreview.current_due_on ?? null,
                          ) ??
                            editPreview.current_due_on ??
                            "—"}
                          ). Elige una fecha inicial posterior o reduce la
                          anticipación.
                        </p>
                      ) : null}
                      <p className="text-text-muted text-xs">
                        {editPreview.final_mode === "count"
                          ? `${editPreview.future_count ?? 0} próximas repeticiones · nuevo final ${formatTaskDueDate(editPreview.final_on ?? null) ?? editPreview.final_on ?? "—"}.`
                          : editPreview.final_on
                            ? `Final inclusivo: ${formatTaskDueDate(editPreview.final_on) ?? editPreview.final_on}.`
                            : "Sin fecha final."}
                      </p>
                      <p className="text-text-secondary">
                        Exclusiones que se conservan:{" "}
                        {editPreview.preserved_exclusion_dates?.length
                          ? editPreview.preserved_exclusion_dates.join(", ")
                          : "ninguna"}
                        .
                      </p>
                      <p className="text-text-secondary">
                        Exclusiones retiradas al confirmar:{" "}
                        {editPreview.removed_exclusion_dates?.length
                          ? editPreview.removed_exclusion_dates.join(", ")
                          : "ninguna"}
                        .
                      </p>
                    </>
                  )}
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
                    (!editingSeries && hasUnsavedChanges) ||
                    Boolean(retryCommand || retryEditCommand)
                  }
                >
                  {isWorking ? "Consultando…" : "Vista previa"}
                </Button>
                {editingSeries &&
                editPreview &&
                !editPreview.requires_date_choice &&
                editPreview.appearance_compatible === true ? (
                  <Button
                    type="button"
                    onClick={() => void saveEdit()}
                    disabled={
                      !isOnline ||
                      isWorking ||
                      isDisabled ||
                      Boolean(retryEditCommand)
                    }
                  >
                    Guardar cambios de próximas repeticiones
                  </Button>
                ) : !editingSeries &&
                  preview &&
                  preview.appearance_compatible === true ? (
                  <Button
                    type="button"
                    onClick={() => void createSeries()}
                    disabled={
                      !isOnline ||
                      isWorking ||
                      isDisabled ||
                      hasUnsavedChanges ||
                      Boolean(retryCommand || retryEditCommand)
                    }
                  >
                    Programar repetición
                  </Button>
                ) : null}
                {retryEditCommand ? (
                  <Button
                    type="button"
                    onClick={() => void retryEdit()}
                    disabled={!isOnline || isWorking}
                  >
                    Reintentar la misma edición
                  </Button>
                ) : retryCommand ? (
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
                    setEditingSeries(false);
                    clearPreview();
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
