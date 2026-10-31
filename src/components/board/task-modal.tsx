"use client";

import {
  IconArrowsRightLeft,
  IconCalendar,
  IconCheck,
  IconChevronDown,
  IconFlag,
  IconTrash,
  IconTypography,
} from "@tabler/icons-react";
import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Modal } from "@/components/ui/modal";
import { TaskEditError } from "@/lib/db/tasks";
import { taskCompletionFollowUp } from "@/lib/task-completion";
import {
  changeTaskEditDraft,
  confirmTaskEditSave,
  createTaskEditWorkflow,
  failTaskEditSave,
  requireTaskEditReconciliation,
  retryTaskEditSave,
  reviewTaskEditConflict,
  startTaskEditSave,
  type TaskEditDraft,
  type TaskEditSaveIntent,
  type TaskEditWorkflowState,
  taskEditSaveFollowUp,
  taskMoveFollowUp,
} from "@/lib/task-edit-workflow";
import type {
  ColumnWithTasks,
  Priority,
  Task,
  TaskCompletionCommand,
  TaskCompletionResult,
  TaskEditableField,
  TaskEditCommand,
  TaskEditConflicts,
  TaskEditResult,
  TaskOrderResult,
} from "@/lib/types";
import { generateUUID } from "@/lib/utils";

interface TaskModalProps {
  task: Task | null;
  columns: ColumnWithTasks[];
  contextLabel: string;
  open: boolean;
  isOnline: boolean;
  onClose: () => void;
  onAfterClose: () => void;
  onReconcileTask: (taskId: string) => Promise<Task | null>;
  onSave: (command: TaskEditCommand) => Promise<TaskEditResult>;
  onSetTaskCompletion: (
    command: TaskCompletionCommand,
  ) => Promise<TaskCompletionResult>;
  onMoveTask: (
    taskId: string,
    targetColumnId: string,
  ) => Promise<TaskOrderResult | null>;
  onDelete: (taskId: string) => void;
}

const priorityOptions: { value: Priority; label: string }[] = [
  { value: "low", label: "Baja" },
  { value: "medium", label: "Media" },
  { value: "high", label: "Alta" },
  { value: "urgent", label: "Urgente" },
];

const editableFields: TaskEditableField[] = [
  "title",
  "description",
  "priority",
];

function draftFor(task: Task): TaskEditDraft {
  return {
    title: task.title,
    description: task.description ?? "",
    priority: task.priority,
  };
}

function fieldLabel(field: TaskEditableField) {
  switch (field) {
    case "title":
      return "Título";
    case "description":
      return "Descripción";
    case "priority":
      return "Prioridad";
  }
}

function displayValue(field: TaskEditableField, value: string | null) {
  if (field === "priority") {
    return (
      priorityOptions.find((option) => option.value === value)?.label ??
      value ??
      "Sin valor"
    );
  }
  if (value === null || value === "") return "Sin contenido";
  return value;
}

function saveErrorMessage(error: unknown) {
  if (!(error instanceof TaskEditError)) {
    return "No se pudo confirmar el guardado. Revisa la conexión antes de volver a intentarlo.";
  }
  switch (error.reason) {
    case "access_denied":
    case "stale_session":
      return "Tu acceso cambió. Se cerrará este detalle para proteger la información.";
    case "rejected":
      return "No se guardaron los cambios. Revisa los campos e inténtalo de nuevo.";
    case "conflict":
      return "No se pudo confirmar esta operación. Vuelve a guardar para revisar los cambios actuales.";
    case "expired_unknown":
      return "El resultado anterior ya no se puede confirmar. Revisa los valores actuales y vuelve a guardar.";
    case "unavailable":
      return "El tablero no está disponible ahora. El borrador sigue en esta pantalla.";
    case "uncertain":
    case "retryable":
      return "No se pudo confirmar el guardado. El borrador sigue aquí; vuelve a intentarlo manualmente.";
  }
}

export function TaskModal({
  task,
  columns,
  contextLabel,
  open,
  isOnline,
  onClose,
  onAfterClose,
  onReconcileTask,
  onSave,
  onSetTaskCompletion,
  onMoveTask,
  onDelete,
}: TaskModalProps) {
  const [baseTask, setBaseTask] = useState<Task | null>(task);
  const [workflow, setWorkflow] = useState<TaskEditWorkflowState>(() =>
    createTaskEditWorkflow(
      task
        ? draftFor(task)
        : { title: "", description: "", priority: "medium" },
    ),
  );
  const [conflicts, setConflicts] = useState<TaskEditConflicts>({});
  const [showDetails, setShowDetails] = useState(false);
  const [showDescription, setShowDescription] = useState(
    Boolean(task?.description),
  );
  const [showCloseChoices, setShowCloseChoices] = useState(false);
  const [closeAction, setCloseAction] = useState<
    "close" | "delete" | "move" | "complete"
  >("close");
  const [closeNotice, setCloseNotice] = useState("");
  const [moveNotice, setMoveNotice] = useState("");
  const [pendingMoveTargetId, setPendingMoveTargetId] = useState<string | null>(
    null,
  );
  const [isMoving, setIsMoving] = useState(false);
  const [pendingCompletionTarget, setPendingCompletionTarget] = useState<
    boolean | null
  >(null);
  const [isCompleting, setIsCompleting] = useState(false);
  const [completionNotice, setCompletionNotice] = useState("");
  const [expiredOperation, setExpiredOperation] =
    useState<TaskEditCommand | null>(null);
  const [reconciliationRequired, setReconciliationRequired] = useState(false);
  const [reconciliationError, setReconciliationError] = useState("");
  const [isReconciling, setIsReconciling] = useState(false);
  const titleInputRef = useRef<HTMLInputElement>(null);

  // A board refresh for this task must not replace an in-session draft.
  // Reset only when the editor opens for a new task identity.
  // biome-ignore lint/correctness/useExhaustiveDependencies: task identity is the reset boundary; live task refreshes must preserve the draft
  useEffect(() => {
    if (!open || !task) return;
    const initialDraft = draftFor(task);
    setBaseTask(task);
    setWorkflow(createTaskEditWorkflow(initialDraft));
    setConflicts({});
    setShowDetails(false);
    setShowDescription(Boolean(task.description));
    setShowCloseChoices(false);
    setCloseAction("close");
    setCloseNotice("");
    setMoveNotice("");
    setPendingMoveTargetId(null);
    setIsMoving(false);
    setPendingCompletionTarget(null);
    setIsCompleting(false);
    setCompletionNotice("");
    setExpiredOperation(null);
    setReconciliationRequired(false);
    setReconciliationError("");
  }, [open, task?.id]);

  const draft = workflow.draft;
  const normalizedTitle = draft.title.trim();
  const normalizedDescription = draft.description.trim() || null;
  const dirty =
    baseTask !== null &&
    (normalizedTitle !== baseTask.title ||
      normalizedDescription !== baseTask.description ||
      draft.priority !== baseTask.priority);
  const hasConflict = Object.keys(conflicts).length > 0;
  const isSaving = workflow.status === "saving";
  const isWorking = isSaving || isReconciling || isMoving || isCompleting;

  useEffect(() => {
    if (!open || !dirty) return;
    function warnBeforeUnload(event: BeforeUnloadEvent) {
      event.preventDefault();
      event.returnValue = "";
    }
    window.addEventListener("beforeunload", warnBeforeUnload);
    return () => window.removeEventListener("beforeunload", warnBeforeUnload);
  }, [dirty, open]);

  function updateDraft(nextDraft: TaskEditDraft) {
    setWorkflow((current) => changeTaskEditDraft(current, nextDraft));
    setCloseNotice("");
    setMoveNotice("");
    setCompletionNotice("");
  }

  function requestClose() {
    if (isWorking) {
      setCloseNotice("Espera a que termine el guardado antes de cerrar.");
      return;
    }
    if (dirty) {
      setCloseAction("close");
      setPendingMoveTargetId(null);
      setPendingCompletionTarget(null);
      setShowCloseChoices(true);
      setCloseNotice("");
      return;
    }
    onClose();
  }

  function requestDelete() {
    if (isWorking) {
      setCloseNotice("Espera a que termine el guardado antes de continuar.");
      return;
    }
    if (dirty) {
      setCloseAction("delete");
      setPendingMoveTargetId(null);
      setPendingCompletionTarget(null);
      setShowCloseChoices(true);
      return;
    }
    if (task) onDelete(task.id);
  }

  function discardAndContinue() {
    if (closeAction === "move") {
      const targetColumnId = pendingMoveTargetId;
      if (!targetColumnId || !baseTask) return;
      setWorkflow(createTaskEditWorkflow(draftFor(baseTask)));
      setConflicts({});
      setShowCloseChoices(false);
      setMoveNotice("");
      if (taskMoveFollowUp("discard") === "move") {
        void performMove(targetColumnId);
      }
      return;
    }
    if (closeAction === "complete") {
      const target = pendingCompletionTarget;
      const currentTask = baseTask;
      if (target === null || !currentTask) return;
      setWorkflow(createTaskEditWorkflow(draftFor(currentTask)));
      setConflicts({});
      setShowCloseChoices(false);
      setCompletionNotice("");
      if (taskCompletionFollowUp("discard") === "complete") {
        void performCompletion(target, currentTask);
      }
      return;
    }
    if (closeAction === "delete") {
      if (task && baseTask) {
        setWorkflow(createTaskEditWorkflow(draftFor(baseTask)));
        setConflicts({});
        setShowCloseChoices(false);
        onDelete(task.id);
      }
      return;
    }
    onClose();
  }

  async function performCompletion(
    target: boolean,
    currentTask?: Task,
    afterSave = false,
  ) {
    const taskSnapshot = currentTask ?? baseTask;
    if (
      !task ||
      !taskSnapshot ||
      (!afterSave && isWorking) ||
      !isOnline ||
      hasConflict ||
      reconciliationRequired
    ) {
      return;
    }
    setIsCompleting(true);
    setCompletionNotice("");
    try {
      const result = await onSetTaskCompletion({
        id: task.id,
        operation_id: generateUUID(),
        is_completed: target,
        expected_version: taskSnapshot.completion_version,
      });
      if (result.status !== "confirmed" && result.status !== "conflict") {
        setCompletionNotice(
          "No se pudo confirmar el cambio de estado. Revisa la tarea antes de volver a elegir la acción.",
        );
        return;
      }
      setBaseTask(result.task);
      if (result.status === "confirmed") {
        setWorkflow(confirmTaskEditSave(draftFor(result.task)));
        setCompletionNotice(target ? "Tarea completada." : "Tarea reabierta.");
      } else {
        setCompletionNotice(
          "El estado cambió o no se pudo confirmar. Actualizamos la tarea; vuelve a elegir la acción.",
        );
      }
    } catch {
      setCompletionNotice(
        "No se pudo confirmar el cambio de estado. Revisa la tarea antes de volver a elegir la acción.",
      );
    } finally {
      setIsCompleting(false);
      setPendingCompletionTarget(null);
      setCloseAction("close");
      setShowCloseChoices(false);
    }
  }

  function requestCompletion() {
    if (!task || !baseTask || isWorking) return;
    const target = !baseTask.is_completed;
    if (!isOnline) {
      setCompletionNotice(
        "Estás sin conexión. La tarea no cambiará de estado.",
      );
      return;
    }
    if (hasConflict || reconciliationRequired) {
      setCompletionNotice(
        "Resuelve el conflicto o consulta el estado actual antes de continuar.",
      );
      return;
    }
    setCompletionNotice("");
    if (dirty) {
      setCloseAction("complete");
      setPendingMoveTargetId(null);
      setPendingCompletionTarget(target);
      setShowCloseChoices(true);
      setCloseNotice("");
      return;
    }
    void performCompletion(target, baseTask);
  }

  function buildOperation(): TaskEditCommand | null {
    if (!baseTask || !task) return null;
    const updates: TaskEditCommand["updates"] = {};
    const expectedVersions: TaskEditCommand["expected_versions"] = {};

    if (normalizedTitle !== baseTask.title) {
      updates.title = normalizedTitle;
      expectedVersions.title = baseTask.field_versions.title;
    }
    if (normalizedDescription !== baseTask.description) {
      updates.description = normalizedDescription;
      expectedVersions.description = baseTask.field_versions.description;
    }
    if (draft.priority !== baseTask.priority) {
      updates.priority = draft.priority;
      expectedVersions.priority = baseTask.field_versions.priority;
    }
    if (Object.keys(updates).length === 0) return null;

    return {
      id: task.id,
      operation_id: generateUUID(),
      updates,
      expected_versions: expectedVersions,
    };
  }

  async function performMove(targetColumnId: string) {
    if (
      !task ||
      isWorking ||
      !isOnline ||
      hasConflict ||
      reconciliationRequired
    ) {
      return;
    }
    setIsMoving(true);
    setMoveNotice("");
    setPendingMoveTargetId(null);
    try {
      const result = await onMoveTask(task.id, targetColumnId);
      if (result?.status === "confirmed") {
        onClose();
      } else if (result?.status === "conflict") {
        setMoveNotice(
          "El orden cambió mientras revisabas. Las columnas se actualizaron; elige de nuevo dónde mover la tarea.",
        );
      } else if (
        result?.status === "uncertain" ||
        result?.status === "retryable" ||
        result?.status === "expired_unknown"
      ) {
        setMoveNotice(
          "No se pudo confirmar el movimiento. El tablero se consultó y la tarea no se moverá hasta que vuelvas a elegir un destino.",
        );
      } else if (result?.status === "access_denied") {
        setMoveNotice("Tu acceso cambió. No se movió la tarea.");
      } else {
        setMoveNotice(
          "No se pudo mover la tarea. Sigue en el tablero para que puedas revisar el estado.",
        );
      }
    } catch {
      setMoveNotice(
        "No se pudo confirmar el movimiento. Revisa el tablero antes de volver a elegir un destino.",
      );
    } finally {
      setIsMoving(false);
    }
  }

  function requestMove(targetColumnId: string) {
    if (isWorking) return;
    if (!isOnline) {
      setMoveNotice("Estás sin conexión. La tarea no se moverá.");
      return;
    }
    if (hasConflict || reconciliationRequired) {
      setMoveNotice("Resuelve o consulta primero el resultado del guardado.");
      return;
    }
    if (dirty) {
      setCloseAction("move");
      setPendingMoveTargetId(targetColumnId);
      setPendingCompletionTarget(null);
      setShowCloseChoices(true);
      setCloseNotice("");
      setMoveNotice("");
      return;
    }
    void performMove(targetColumnId);
  }

  async function save(
    intent: TaskEditSaveIntent = "stay",
    moveAfterSave = false,
    completeAfterSave = false,
  ) {
    if (
      !task ||
      !baseTask ||
      isWorking ||
      !isOnline ||
      hasConflict ||
      reconciliationRequired
    )
      return;

    const retry = retryTaskEditSave(workflow);
    const operation = retry?.operation ?? buildOperation();
    if (!operation) {
      if (taskEditSaveFollowUp(intent, "confirmed") === "close") onClose();
      if (
        completeAfterSave &&
        closeAction === "complete" &&
        pendingCompletionTarget !== null &&
        taskCompletionFollowUp("save", "confirmed") === "complete"
      ) {
        await performCompletion(pendingCompletionTarget, baseTask, true);
      }
      return;
    }

    const savingState = retry
      ? retry.state
      : startTaskEditSave(workflow, operation);
    setWorkflow(savingState);
    setCloseNotice("");
    try {
      const result = await onSave(operation);
      if (result.status === "conflict") {
        setBaseTask(result.task);
        setConflicts(result.conflicts);
        setWorkflow(reviewTaskEditConflict({ ...savingState, draft }));
        setExpiredOperation(null);
        setReconciliationRequired(false);
        setReconciliationError("");
        setShowCloseChoices(false);
        return;
      }

      if (result.status !== "confirmed") {
        throw new Error("The task edit result was not confirmed.");
      }
      setBaseTask(result.task);
      const confirmedDraft = draftFor(result.task);
      setWorkflow(confirmTaskEditSave(confirmedDraft));
      setConflicts({});
      setExpiredOperation(null);
      setReconciliationRequired(false);
      setReconciliationError("");
      setShowCloseChoices(false);
      const followUp = taskEditSaveFollowUp(intent, "confirmed");
      if (followUp === "close") onClose();
      if (followUp === "confirm-delete") onDelete(task.id);
      if (
        completeAfterSave &&
        closeAction === "complete" &&
        pendingCompletionTarget !== null &&
        taskCompletionFollowUp("save", "confirmed") === "complete"
      ) {
        await performCompletion(pendingCompletionTarget, result.task, true);
      } else if (
        moveAfterSave &&
        closeAction === "move" &&
        pendingMoveTargetId &&
        taskMoveFollowUp("save", "confirmed") === "move"
      ) {
        await performMove(pendingMoveTargetId);
      } else if (closeAction === "move") {
        setCloseAction("close");
        setPendingMoveTargetId(null);
      }
    } catch (error) {
      if (
        error instanceof TaskEditError &&
        (error.reason === "expired_unknown" || error.reason === "conflict")
      ) {
        const message = saveErrorMessage(error);
        setExpiredOperation(operation);
        setReconciliationRequired(true);
        setReconciliationError(message);
        setWorkflow(requireTaskEditReconciliation(savingState, message));
      } else {
        setWorkflow(failTaskEditSave(savingState, saveErrorMessage(error)));
      }
      setShowCloseChoices(false);
    }
  }

  async function reconcileExpiredOperation() {
    if (!task || !expiredOperation || !isOnline || isWorking) return;
    setIsReconciling(true);
    setReconciliationError("");
    try {
      const latestTask = await onReconcileTask(task.id);
      if (!latestTask) throw new Error("La tarea ya no está disponible.");
      const nextConflicts: TaskEditConflicts = {};
      const titleDraft = draft.title.trim();
      const descriptionDraft = draft.description.trim() || null;
      if (
        Object.hasOwn(expiredOperation.updates, "title") ||
        titleDraft !== latestTask.title
      ) {
        nextConflicts.title = {
          current: latestTask.title,
          draft: titleDraft,
          current_version: latestTask.field_versions.title,
        };
      }
      if (
        Object.hasOwn(expiredOperation.updates, "description") ||
        descriptionDraft !== latestTask.description
      ) {
        nextConflicts.description = {
          current: latestTask.description,
          draft: descriptionDraft,
          current_version: latestTask.field_versions.description,
        };
      }
      if (
        Object.hasOwn(expiredOperation.updates, "priority") ||
        draft.priority !== latestTask.priority
      ) {
        nextConflicts.priority = {
          current: latestTask.priority,
          draft: draft.priority,
          current_version: latestTask.field_versions.priority,
        };
      }
      setBaseTask(latestTask);
      setConflicts(nextConflicts);
      setWorkflow(reviewTaskEditConflict({ ...workflow, operation: null }));
      setExpiredOperation(null);
      setReconciliationRequired(false);
    } catch {
      setReconciliationError(
        "No se pudieron consultar los valores actuales. El borrador se conserva y no se repetirá la operación vencida.",
      );
    } finally {
      setIsReconciling(false);
    }
  }

  function continueEditing() {
    setShowCloseChoices(false);
    setCloseAction("close");
    setPendingMoveTargetId(null);
    setPendingCompletionTarget(null);
    window.requestAnimationFrame(() =>
      titleInputRef.current?.focus({ preventScroll: true }),
    );
  }

  function resolveConflict(field: TaskEditableField, keepDraft: boolean) {
    if (!baseTask) return;
    const nextConflicts = { ...conflicts };
    delete nextConflicts[field];
    setConflicts(nextConflicts);
    if (!keepDraft) {
      const currentValue = baseTask[field];
      updateDraft({
        ...draft,
        [field]: field === "description" ? (currentValue ?? "") : currentValue,
      });
    }
    if (Object.keys(nextConflicts).length === 0) {
      setWorkflow((current) => ({
        ...current,
        status: "idle",
        error: null,
        operation: null,
      }));
    }
  }

  if (!open || !task || !baseTask || baseTask.id !== task.id) return null;

  const date = new Date(task.created_at).toLocaleDateString("es-AR", {
    day: "numeric",
    month: "short",
    year: "numeric",
  });
  const otherColumns = columns.filter((column) => column.id !== task.column_id);

  return (
    <Modal
      open={open}
      onClose={requestClose}
      title="Detalle de la tarea"
      fullScreenMobile
      closeLabel="Cerrar detalle de tarea"
      onAfterClose={onAfterClose}
    >
      <div className="flex min-h-[calc(100dvh-5rem)] flex-col gap-5 sm:min-h-0">
        <div>
          <p className="mb-3 text-text-muted text-xs">{contextLabel}</p>
          <label
            htmlFor="task-title"
            className="mb-2 flex items-center gap-1.5 font-semibold text-text-muted text-xs"
          >
            <IconTypography size={14} aria-hidden="true" /> Título
          </label>
          <input
            id="task-title"
            ref={titleInputRef}
            data-modal-autofocus
            value={draft.title}
            disabled={isWorking}
            onChange={(event) =>
              updateDraft({ ...draft, title: event.target.value })
            }
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                event.preventDefault();
                void save();
              }
            }}
            placeholder="¿Qué hay que hacer?"
            className="w-full rounded-md border border-border bg-transparent px-3 py-3 font-medium text-base text-text-primary outline-none transition-colors placeholder:text-text-muted/60 focus:border-accent focus:ring-1 focus:ring-accent disabled:opacity-60"
          />
        </div>

        <section aria-labelledby="task-description-heading">
          <div className="mb-2 flex items-center justify-between">
            <h3
              id="task-description-heading"
              className="font-semibold text-sm text-text-primary"
            >
              Descripción
            </h3>
            {!showDescription && (
              <Button
                size="sm"
                variant="ghost"
                onClick={() => setShowDescription(true)}
                aria-expanded={false}
              >
                Añadir descripción
              </Button>
            )}
          </div>
          {showDescription && (
            <textarea
              id="task-description"
              aria-label="Descripción de la tarea"
              value={draft.description}
              disabled={isWorking}
              onChange={(event) =>
                updateDraft({ ...draft, description: event.target.value })
              }
              rows={5}
              placeholder="Añade los detalles necesarios para completar la tarea."
              className="w-full resize-y rounded-md border border-border bg-transparent px-3 py-2.5 text-sm text-text-primary outline-none transition-colors placeholder:text-text-muted/60 focus:border-accent focus:ring-1 focus:ring-accent disabled:opacity-60"
            />
          )}
        </section>

        <section className="border-border border-t pt-3">
          <button
            type="button"
            className="flex w-full items-center justify-between rounded-md py-2 text-left font-medium text-sm text-text-secondary hover:text-text-primary"
            aria-expanded={showDetails}
            onClick={() => setShowDetails((shown) => !shown)}
          >
            <span>Más detalles</span>
            <IconChevronDown
              size={16}
              className={showDetails ? "rotate-180" : ""}
              aria-hidden="true"
            />
          </button>
          {showDetails && (
            <div className="grid grid-cols-1 gap-4 pt-2 sm:grid-cols-2">
              <div className="flex flex-col gap-2">
                <label
                  htmlFor="task-priority"
                  className="flex items-center gap-1.5 font-semibold text-text-muted text-xs"
                >
                  <IconFlag size={14} aria-hidden="true" /> Prioridad
                </label>
                <DropdownMenu>
                  <DropdownMenuTrigger
                    id="task-priority"
                    disabled={isWorking}
                    className="flex h-11 w-full items-center justify-between rounded-md border border-border bg-transparent px-3 py-2 text-left font-medium text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60 data-[status=open]:border-accent"
                  >
                    <span>
                      {
                        priorityOptions.find(
                          (option) => option.value === draft.priority,
                        )?.label
                      }
                    </span>
                    <IconChevronDown
                      size={16}
                      className="text-text-muted"
                      aria-hidden="true"
                    />
                  </DropdownMenuTrigger>
                  <DropdownMenuContent
                    align="start"
                    className="w-(--anchor-width) border border-border bg-surface-raised"
                  >
                    {priorityOptions.map((option) => (
                      <DropdownMenuItem
                        key={option.value}
                        onClick={() =>
                          updateDraft({ ...draft, priority: option.value })
                        }
                        className="flex cursor-pointer items-center justify-between"
                      >
                        {option.label}
                        {draft.priority === option.value && (
                          <IconCheck size={14} aria-hidden="true" />
                        )}
                      </DropdownMenuItem>
                    ))}
                  </DropdownMenuContent>
                </DropdownMenu>
              </div>
              <div className="flex flex-col gap-2">
                <span className="flex items-center gap-1.5 font-semibold text-text-muted text-xs">
                  <IconCalendar size={14} aria-hidden="true" /> Creada
                </span>
                <div className="flex h-11 items-center px-3 text-sm text-text-secondary">
                  <time dateTime={task.created_at}>{date}</time>
                </div>
              </div>
            </div>
          )}
        </section>

        <section className="flex items-center justify-between gap-3 border-border border-t pt-3">
          <div>
            <p className="font-medium text-sm text-text-primary">
              {baseTask.is_completed ? "Tarea completada" : "Tarea pendiente"}
            </p>
            <p className="mt-1 text-text-muted text-xs">
              El estado no cambia al abrir este detalle.
            </p>
          </div>
          <Button
            variant={baseTask.is_completed ? "ghost" : "primary"}
            onClick={requestCompletion}
            disabled={
              isWorking || !isOnline || hasConflict || reconciliationRequired
            }
          >
            {baseTask.is_completed ? "Reabrir" : "Completar"}
          </Button>
        </section>

        {otherColumns.length > 0 && (
          <section className="border-border border-t pt-3">
            <DropdownMenu>
              <DropdownMenuTrigger
                disabled={
                  isWorking ||
                  !isOnline ||
                  hasConflict ||
                  reconciliationRequired
                }
                className="flex min-h-10 items-center gap-2 rounded-md border border-border px-3 text-sm text-text-secondary outline-none hover:bg-surface-hover hover:text-text-primary focus-visible:ring-1 focus-visible:ring-accent disabled:cursor-not-allowed disabled:opacity-50"
              >
                <IconArrowsRightLeft size={16} aria-hidden="true" />
                Mover a otra columna
                <IconChevronDown size={14} aria-hidden="true" />
              </DropdownMenuTrigger>
              <DropdownMenuContent align="start" className="min-w-56">
                {otherColumns.map((column) => (
                  <DropdownMenuItem
                    key={column.id}
                    onClick={() => requestMove(column.id)}
                    className="cursor-pointer"
                  >
                    {column.title}
                  </DropdownMenuItem>
                ))}
              </DropdownMenuContent>
            </DropdownMenu>
          </section>
        )}

        {moveNotice && (
          <output
            aria-live="polite"
            className="rounded-md border border-priority-medium/30 bg-priority-medium/10 p-3 text-priority-medium text-sm"
          >
            {moveNotice}
          </output>
        )}

        {completionNotice && (
          <output
            aria-live="polite"
            className="rounded-md border border-priority-medium/30 bg-priority-medium/10 p-3 text-priority-medium text-sm"
          >
            {completionNotice}
          </output>
        )}

        {!isOnline && (
          <output
            aria-live="polite"
            className="rounded-md border border-priority-medium/30 bg-priority-medium/10 p-3 text-priority-medium text-sm"
          >
            Estás sin conexión. El borrador queda solo en esta pantalla y no se
            enviará automáticamente al reconectar.
          </output>
        )}

        {workflow.status === "saving" && (
          <output aria-live="polite" className="text-sm text-text-secondary">
            Guardando cambios…
          </output>
        )}
        {workflow.status === "saved" && (
          <output aria-live="polite" className="text-priority-low text-sm">
            Cambios guardados.
          </output>
        )}
        {workflow.status === "error" && workflow.error && (
          <div
            role="alert"
            className="rounded-md border border-priority-urgent/30 bg-priority-urgent/10 p-3 text-priority-urgent text-sm"
          >
            <p>{workflow.error}</p>
            {workflow.operation && (
              <p className="mt-1 text-xs">
                No habrá otro intento hasta que elijas Guardar de nuevo.
              </p>
            )}
          </div>
        )}

        {reconciliationRequired && (
          <section
            className="rounded-md border border-priority-medium/40 bg-priority-medium/10 p-3"
            aria-labelledby="task-reconcile-heading"
          >
            <h3
              id="task-reconcile-heading"
              className="font-semibold text-sm text-text-primary"
            >
              Revisa el resultado anterior
            </h3>
            <output
              aria-live="polite"
              className="mt-1 text-sm text-text-secondary"
            >
              {reconciliationError}
            </output>
            <Button
              size="sm"
              variant="primary"
              className="mt-3"
              onClick={() => void reconcileExpiredOperation()}
              disabled={!isOnline || isWorking || !expiredOperation}
            >
              {isReconciling ? "Consultando…" : "Consultar valores actuales"}
            </Button>
          </section>
        )}

        {hasConflict && (
          <section
            className="space-y-3 rounded-md border border-priority-medium/40 bg-priority-medium/10 p-3"
            aria-labelledby="task-conflict-heading"
          >
            <h3
              id="task-conflict-heading"
              className="font-semibold text-sm text-text-primary"
            >
              Hay cambios en conflicto
            </h3>
            <p className="text-sm text-text-secondary">
              Revisa cada campo. Puedes usar el valor actual o conservar tu
              borrador; no se combinará texto automáticamente.
            </p>
            {editableFields.map((field) => {
              const conflict = conflicts[field];
              if (!conflict) return null;
              return (
                <div
                  key={field}
                  className="space-y-2 border-border/70 border-t pt-3"
                >
                  <h4 className="font-semibold text-sm text-text-primary">
                    {fieldLabel(field)}
                  </h4>
                  <p className="break-words text-text-secondary text-xs">
                    Valor actual:{" "}
                    <span className="whitespace-pre-wrap">
                      {displayValue(field, conflict.current)}
                    </span>
                  </p>
                  <p className="break-words text-text-secondary text-xs">
                    Tu borrador:{" "}
                    <span className="whitespace-pre-wrap">
                      {displayValue(field, conflict.draft)}
                    </span>
                  </p>
                  <div className="flex flex-wrap gap-2">
                    <Button
                      size="sm"
                      variant="ghost"
                      onClick={() => resolveConflict(field, false)}
                    >
                      Usar el valor actual
                    </Button>
                    <Button
                      size="sm"
                      variant="primary"
                      onClick={() => resolveConflict(field, true)}
                    >
                      Conservar mi borrador
                    </Button>
                  </div>
                </div>
              );
            })}
          </section>
        )}

        {showCloseChoices && (
          <section
            className="rounded-md border border-border bg-surface-raised p-4"
            aria-labelledby="task-close-heading"
          >
            <h3
              id="task-close-heading"
              className="font-semibold text-sm text-text-primary"
            >
              {closeAction === "close"
                ? "¿Qué quieres hacer con los cambios?"
                : "Hay cambios sin guardar"}
            </h3>
            <p className="mt-1 text-sm text-text-secondary">
              El borrador vive solo en esta sesión y no se recupera si recargas
              o cierras la página.
            </p>
            {closeAction === "delete" && (
              <p className="mt-1 text-sm text-text-secondary">
                Si se confirma el guardado, aparecerá la confirmación de
                eliminación. Si hay un error o conflicto, el borrador seguirá
                aquí.
              </p>
            )}
            {closeAction === "move" && (
              <p className="mt-1 text-sm text-text-secondary">
                La tarea solo se moverá si confirmas el guardado o descartas el
                borrador. Si guardar falla o hay un conflicto, el movimiento se
                detiene y podrás revisar el estado actual.
              </p>
            )}
            {closeAction === "complete" && (
              <p className="mt-1 text-sm text-text-secondary">
                La tarea solo cambiará de estado si confirmas el guardado o
                descartas el borrador. Si guardar falla o hay un conflicto, la
                acción se detiene.
              </p>
            )}
            {closeNotice && (
              <output
                aria-live="polite"
                className="mt-2 text-priority-medium text-sm"
              >
                {closeNotice}
              </output>
            )}
            <div className="mt-4 flex flex-col-reverse gap-2 sm:flex-row sm:flex-wrap sm:justify-end">
              {closeAction === "close" && (
                <Button
                  variant="primary"
                  onClick={() => void save("close")}
                  disabled={
                    !dirty ||
                    !normalizedTitle ||
                    !isOnline ||
                    hasConflict ||
                    isWorking ||
                    reconciliationRequired
                  }
                >
                  Guardar y cerrar
                </Button>
              )}
              {closeAction === "delete" && (
                <Button
                  variant="primary"
                  onClick={() => void save("delete")}
                  disabled={
                    !dirty ||
                    !normalizedTitle ||
                    !isOnline ||
                    hasConflict ||
                    isWorking ||
                    reconciliationRequired
                  }
                >
                  Guardar y continuar
                </Button>
              )}
              {closeAction === "move" && (
                <Button
                  variant="primary"
                  onClick={() => void save("stay", true)}
                  disabled={
                    !dirty ||
                    !normalizedTitle ||
                    !isOnline ||
                    hasConflict ||
                    isWorking ||
                    reconciliationRequired ||
                    !pendingMoveTargetId
                  }
                >
                  Guardar y mover
                </Button>
              )}
              {closeAction === "complete" && (
                <Button
                  variant="primary"
                  onClick={() => void save("stay", false, true)}
                  disabled={
                    !dirty ||
                    !normalizedTitle ||
                    !isOnline ||
                    hasConflict ||
                    isWorking ||
                    reconciliationRequired
                  }
                >
                  {pendingCompletionTarget
                    ? "Guardar y completar"
                    : "Guardar y reabrir"}
                </Button>
              )}
              <Button
                variant="danger"
                onClick={discardAndContinue}
                disabled={isWorking}
              >
                {closeAction === "delete"
                  ? "Descartar y continuar con la eliminación"
                  : closeAction === "move"
                    ? "Descartar cambios y mover"
                    : closeAction === "complete"
                      ? pendingCompletionTarget
                        ? "Descartar cambios y completar"
                        : "Descartar cambios y reabrir"
                      : "Descartar cambios"}
              </Button>
              <Button
                variant="ghost"
                onClick={continueEditing}
                disabled={isWorking}
              >
                Seguir editando
              </Button>
            </div>
          </section>
        )}

        <div className="mt-auto flex flex-col gap-3 border-border border-t pt-4 sm:flex-row sm:items-center sm:justify-between">
          <Button
            variant="danger"
            size="sm"
            onClick={requestDelete}
            disabled={isWorking}
            className="justify-start"
          >
            <IconTrash size={16} aria-hidden="true" /> Eliminar tarea
          </Button>
          <div className="flex flex-col-reverse gap-2 sm:flex-row sm:items-center">
            <Button
              variant="ghost"
              size="sm"
              onClick={requestClose}
              disabled={isWorking}
            >
              Cerrar
            </Button>
            <Button
              variant="primary"
              size="md"
              onClick={() => void save()}
              disabled={
                !dirty ||
                isWorking ||
                !isOnline ||
                hasConflict ||
                reconciliationRequired ||
                !normalizedTitle
              }
              className="font-semibold sm:px-5"
            >
              {isSaving ? "Guardando…" : "Guardar campos"}
            </Button>
          </div>
        </div>
        {closeNotice && !showCloseChoices && (
          <output aria-live="polite" className="text-priority-medium text-sm">
            {closeNotice}
          </output>
        )}
      </div>
    </Modal>
  );
}
