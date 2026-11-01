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
import { useEffect, useMemo, useRef, useState } from "react";
import { TaskConversation } from "@/components/board/task-conversation";
import { TaskDueDate } from "@/components/board/task-due-date";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Modal } from "@/components/ui/modal";
import { TaskChecklistError, TaskEditError } from "@/lib/db/tasks";
import { resolveTaskChecklistCompletionReview } from "@/lib/task-checklist-completion";
import {
  getOrCreateTaskChecklistAddCommand,
  getTaskChecklistCompletionReview,
  getTaskChecklistProgress,
  moveTaskChecklistStep,
  settleTaskChecklistAddOperation,
  shouldClearTaskChecklistAddText,
  type TaskChecklistAddOperationStore,
  type TaskChecklistCompletionReview,
  type TaskChecklistMutationOutcome,
} from "@/lib/task-checklist-state";
import type { TaskCommentCreateOperationStore } from "@/lib/task-comments-state";
import { taskCompletionFollowUp } from "@/lib/task-completion";
import { formatTaskDueDate, isDateOnly } from "@/lib/task-date";
import {
  type PreservedTaskDraft,
  rebasePreservedTaskDraft,
} from "@/lib/task-draft-preservation";
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
  AssignableBoardMember,
  ColumnWithTasks,
  Priority,
  Task,
  TaskAssigneeCommand,
  TaskAssigneeResult,
  TaskChecklistCommand,
  TaskChecklistResult,
  TaskCompletionCommand,
  TaskCompletionResult,
  TaskEditableField,
  TaskEditCommand,
  TaskEditConflicts,
  TaskEditResult,
  TaskFieldVersions,
  TaskOrderResult,
} from "@/lib/types";
import { generateUUID } from "@/lib/utils";

interface TaskModalProps {
  task: Task | null;
  restoredDraft: PreservedTaskDraft | null;
  onEditDraftChange: (
    taskId: string,
    draft: TaskEditDraft,
    dirtyFields: TaskEditableField[],
    baseVersions: TaskFieldVersions,
  ) => void;
  onEditDraftRestored: () => void;
  slug: string;
  actorId: string;
  role: "owner" | "collaborator";
  initialCommentId: string | null;
  commentOperations: TaskCommentCreateOperationStore;
  isSessionStale: boolean;
  onConversationAccessLost: () => void;
  boardTimeZone: string;
  boardToday: string;
  columns: ColumnWithTasks[];
  contextLabel: string;
  open: boolean;
  isOnline: boolean;
  onClose: () => void;
  onAfterClose: () => void;
  onReconcileTask: (taskId: string) => Promise<Task | null>;
  onSave: (command: TaskEditCommand) => Promise<TaskEditResult>;
  assignableMembers: AssignableBoardMember[] | null;
  onSetTaskAssignee: (
    command: TaskAssigneeCommand,
  ) => Promise<TaskAssigneeResult>;
  onSetTaskCompletion: (
    command: TaskCompletionCommand,
  ) => Promise<TaskCompletionResult>;
  checklistAddOperations: TaskChecklistAddOperationStore;
  onMutateChecklist: (
    command: TaskChecklistCommand,
  ) => Promise<TaskChecklistResult>;
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
  "due_on",
];

function draftFor(task: Task): TaskEditDraft {
  return {
    title: task.title,
    description: task.description ?? "",
    priority: task.priority,
    due_on: task.due_on ?? "",
  };
}

function dirtyTaskEditFields(
  task: Task,
  draft: TaskEditDraft,
): TaskEditableField[] {
  return editableFields.filter((field) => {
    switch (field) {
      case "title":
        return draft.title.trim() !== task.title;
      case "description":
        return (draft.description.trim() || null) !== task.description;
      case "priority":
        return draft.priority !== task.priority;
      case "due_on":
        return (draft.due_on || null) !== task.due_on;
    }
    return false;
  });
}

function fieldLabel(field: TaskEditableField) {
  switch (field) {
    case "title":
      return "Título";
    case "description":
      return "Descripción";
    case "priority":
      return "Prioridad";
    case "due_on":
      return "Fecha límite";
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
  if (field === "due_on") {
    return formatTaskDueDate(value) ?? "Sin fecha";
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
  restoredDraft,
  onEditDraftChange,
  onEditDraftRestored,
  slug,
  actorId,
  role,
  initialCommentId,
  commentOperations,
  isSessionStale,
  onConversationAccessLost,
  boardTimeZone,
  boardToday,
  columns,
  contextLabel,
  open,
  isOnline,
  onClose,
  onAfterClose,
  onReconcileTask,
  onSave,
  assignableMembers,
  onSetTaskAssignee,
  onSetTaskCompletion,
  checklistAddOperations,
  onMutateChecklist,
  onMoveTask,
  onDelete,
}: TaskModalProps) {
  const initialRestoration =
    task && restoredDraft
      ? rebasePreservedTaskDraft(task, restoredDraft)
      : null;
  const [baseTask, setBaseTask] = useState<Task | null>(task);
  const [workflow, setWorkflow] = useState<TaskEditWorkflowState>(() =>
    createTaskEditWorkflow(
      initialRestoration?.draft ??
        (task
          ? draftFor(task)
          : { title: "", description: "", priority: "medium", due_on: "" }),
    ),
  );
  const [conflicts, setConflicts] = useState<TaskEditConflicts>(
    () => initialRestoration?.conflicts ?? {},
  );
  const [draftPreservationBaseVersions, setDraftPreservationBaseVersions] =
    useState<TaskFieldVersions | null>(() => task?.field_versions ?? null);
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
  const [pendingChecklistReview, setPendingChecklistReview] =
    useState<TaskChecklistCompletionReview | null>(null);
  const [
    pendingChecklistCompletionCommand,
    setPendingChecklistCompletionCommand,
  ] = useState<TaskCompletionCommand | null>(null);
  const [isChecklistWorking, setIsChecklistWorking] = useState(false);
  const [checklistNotice, setChecklistNotice] = useState("");
  const [pendingChecklistAddCommand, setPendingChecklistAddCommand] =
    useState<TaskChecklistCommand | null>(() =>
      task ? checklistAddOperations.get(task.id) : null,
    );
  const pendingChecklistAddCommandRef = useRef(pendingChecklistAddCommand);
  const [newChecklistStepText, setNewChecklistStepText] = useState("");
  const [editingChecklistStepId, setEditingChecklistStepId] = useState<
    string | null
  >(null);
  const [editingChecklistStepText, setEditingChecklistStepText] = useState("");
  const [selectedAssigneeId, setSelectedAssigneeId] = useState(
    task?.assignee_id ?? "",
  );
  const [isAssigning, setIsAssigning] = useState(false);
  const [assigneeNotice, setAssigneeNotice] = useState("");
  const [dueOnError, setDueOnError] = useState("");
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
    const restoration =
      restoredDraft !== null
        ? rebasePreservedTaskDraft(task, restoredDraft)
        : null;
    const initialDraft = restoration?.draft ?? draftFor(task);
    const preservationVersions = { ...task.field_versions };
    if (restoredDraft) {
      for (const field of restoredDraft.dirtyFields) {
        const originalVersion = restoredDraft.baseVersions[field];
        if (originalVersion !== undefined) {
          preservationVersions[field] = originalVersion;
        }
      }
    }
    setBaseTask(task);
    setWorkflow(createTaskEditWorkflow(initialDraft));
    setConflicts(restoration?.conflicts ?? {});
    setDraftPreservationBaseVersions(preservationVersions);
    onEditDraftChange(
      task.id,
      initialDraft,
      dirtyTaskEditFields(task, initialDraft),
      preservationVersions,
    );
    if (restoredDraft) onEditDraftRestored();
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
    setPendingChecklistReview(null);
    setPendingChecklistCompletionCommand(null);
    setIsChecklistWorking(false);
    const pendingAddCommand = checklistAddOperations.get(task.id);
    pendingChecklistAddCommandRef.current = pendingAddCommand;
    setPendingChecklistAddCommand(pendingAddCommand);
    setChecklistNotice(
      pendingAddCommand
        ? "No se pudo confirmar el paso. Reintenta esta misma alta antes de agregar otro."
        : "",
    );
    setNewChecklistStepText(
      pendingAddCommand?.command.action === "add"
        ? pendingAddCommand.command.text
        : "",
    );
    setEditingChecklistStepId(null);
    setEditingChecklistStepText("");
    setSelectedAssigneeId(task.assignee_id ?? "");
    setIsAssigning(false);
    setAssigneeNotice("");
    setDueOnError("");
    setExpiredOperation(null);
    setReconciliationRequired(false);
    setReconciliationError("");
  }, [open, task?.id]);

  const draft = workflow.draft;
  const normalizedTitle = draft.title.trim();
  const normalizedDescription = draft.description.trim() || null;
  const dirtyFields = useMemo(
    () => (baseTask ? dirtyTaskEditFields(baseTask, draft) : []),
    [baseTask, draft],
  );
  const dirty = dirtyFields.length > 0;
  const hasConflict = Object.keys(conflicts).length > 0;
  const isSaving = workflow.status === "saving";
  const isWorking =
    isSaving ||
    isReconciling ||
    isMoving ||
    isCompleting ||
    isAssigning ||
    isChecklistWorking;

  useEffect(() => {
    if (!task || !baseTask) return;
    onEditDraftChange(
      task.id,
      draft,
      dirtyFields,
      draftPreservationBaseVersions ?? baseTask.field_versions,
    );
  }, [
    baseTask,
    draft,
    dirtyFields,
    draftPreservationBaseVersions,
    onEditDraftChange,
    task,
  ]);

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
    if (task && baseTask) {
      onEditDraftChange(
        task.id,
        nextDraft,
        dirtyTaskEditFields(baseTask, nextDraft),
        draftPreservationBaseVersions ?? baseTask.field_versions,
      );
    }
    setDueOnError("");
    setCloseNotice("");
    setMoveNotice("");
    setCompletionNotice("");
  }

  async function saveAssignee() {
    if (!task || !baseTask || isWorking) return;
    if (!assignableMembers) {
      setAssigneeNotice(
        "No se pudieron cargar los miembros del tablero. Actualiza para volver a intentarlo.",
      );
      return;
    }
    const assigneeId = selectedAssigneeId || null;
    if (assigneeId === baseTask.assignee_id) return;

    setIsAssigning(true);
    setAssigneeNotice("");
    try {
      const result = await onSetTaskAssignee({
        id: task.id,
        operation_id: generateUUID(),
        assignee_id: assigneeId,
        expected_version: baseTask.assignee_version,
      });
      if (result.status === "confirmed" || result.status === "conflict") {
        setBaseTask((current) =>
          current
            ? {
                ...current,
                assignee_id: result.task.assignee_id,
                assignee_version: result.task.assignee_version,
              }
            : current,
        );
        setSelectedAssigneeId(result.task.assignee_id ?? "");
      }
      if (result.status === "confirmed") {
        setAssigneeNotice("Responsable actualizado.");
      } else if (result.status === "conflict") {
        setAssigneeNotice(
          "El responsable cambió en otro momento. Actualizamos el valor actual; vuelve a elegir si quieres cambiarlo.",
        );
      } else {
        setAssigneeNotice(
          "No se pudo confirmar el cambio. Actualiza los datos antes de volver a intentarlo.",
        );
      }
    } catch (error) {
      setAssigneeNotice(
        error instanceof Error &&
          "reason" in error &&
          error.reason === "rejected"
          ? "Solo puedes asignar a un miembro habilitado de este tablero."
          : error instanceof Error &&
              "reason" in error &&
              error.reason === "access_denied"
            ? "Tu acceso al tablero cambió. Actualiza la página antes de continuar."
            : "No se pudo confirmar el responsable. Actualiza los datos antes de volver a intentarlo.",
      );
    } finally {
      setIsAssigning(false);
    }
  }

  function requestClose() {
    if (pendingChecklistReview) {
      cancelChecklistCompletionReview();
      return;
    }
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
    const command: TaskCompletionCommand = {
      id: task.id,
      operation_id: generateUUID(),
      is_completed: target,
      expected_version: taskSnapshot.completion_version,
    };
    await submitCompletion(command, afterSave);
  }

  async function submitCompletion(
    command: TaskCompletionCommand,
    afterSave = false,
  ) {
    setIsCompleting(true);
    setCompletionNotice("");
    try {
      const result = await onSetTaskCompletion(command);
      const checklistReview = getTaskChecklistCompletionReview(result);
      if (
        checklistReview &&
        (result.status === "confirmation_required" ||
          result.status === "conflict")
      ) {
        setPendingChecklistCompletionCommand({
          ...command,
          operation_id: checklistReview.operationId,
          expected_version: result.task.completion_version,
        });
        setPendingChecklistReview(checklistReview);
        setBaseTask(result.task);
        if (afterSave) setWorkflow(confirmTaskEditSave(draftFor(result.task)));
        setCompletionNotice("");
        return;
      }
      setPendingChecklistReview(null);
      setPendingChecklistCompletionCommand(null);
      if (result.status !== "confirmed" && result.status !== "conflict") {
        setCompletionNotice(
          "No se pudo confirmar el cambio de estado. Revisa la tarea antes de volver a elegir la acción.",
        );
        return;
      }
      setBaseTask(result.task);
      if (result.status === "confirmed") {
        setWorkflow(confirmTaskEditSave(draftFor(result.task)));
        setCompletionNotice(
          command.is_completed ? "Tarea completada." : "Tarea reabierta.",
        );
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

  function cancelChecklistCompletionReview() {
    if (!pendingChecklistCompletionCommand || !pendingChecklistReview) return;
    const commandAfterCancellation = resolveTaskChecklistCompletionReview(
      pendingChecklistCompletionCommand,
      pendingChecklistReview,
      "cancel",
    );
    if (commandAfterCancellation !== null) return;
    setPendingChecklistReview(null);
    setPendingChecklistCompletionCommand(null);
  }

  function acceptChecklistCompletionReview() {
    if (!pendingChecklistCompletionCommand || !pendingChecklistReview) return;
    if (!isOnline) {
      setCompletionNotice(
        "Estás sin conexión. La tarea no cambiará de estado.",
      );
      return;
    }
    const command = resolveTaskChecklistCompletionReview(
      pendingChecklistCompletionCommand,
      pendingChecklistReview,
      "accept",
    );
    if (!command) {
      cancelChecklistCompletionReview();
      return;
    }
    void submitCompletion(command);
  }

  async function mutateChecklist(
    mutation: TaskChecklistCommand["command"],
    successMessage: string,
    operationId = generateUUID(),
  ): Promise<TaskChecklistMutationOutcome> {
    if (!task || !baseTask || isChecklistWorking || !isOnline) {
      return "unresolved";
    }
    setIsChecklistWorking(true);
    setChecklistNotice("");
    try {
      const result = await onMutateChecklist({
        id: task.id,
        operation_id: operationId,
        command: mutation,
      });
      if (result.status === "confirmed" || result.status === "conflict") {
        setBaseTask((current) =>
          current
            ? {
                ...current,
                steps: result.task.steps,
                steps_order_version: result.task.steps_order_version,
                checklist_version: result.task.checklist_version,
              }
            : current,
        );
        if (result.status === "confirmed") {
          setChecklistNotice(successMessage);
          return "confirmed";
        } else {
          setChecklistNotice(
            "La checklist cambió en otro momento. Actualizamos sus pasos; revisa antes de volver a intentar.",
          );
          return "resolved";
        }
      } else {
        setChecklistNotice(
          "No se pudo confirmar el cambio de checklist. Actualiza la tarea antes de volver a intentarlo.",
        );
        return "unresolved";
      }
    } catch (error) {
      setChecklistNotice(
        error instanceof TaskChecklistError && error.reason === "access_denied"
          ? "Tu acceso al tablero cambió. Actualiza la página antes de continuar."
          : "No se pudo confirmar el cambio de checklist. Actualiza la tarea antes de volver a intentarlo.",
      );
      if (error instanceof TaskChecklistError) {
        if (error.reason === "rejected") return "resolved";
        if (error.reason === "access_denied") return "access_lost";
      }
      return "unresolved";
    } finally {
      setIsChecklistWorking(false);
    }
  }

  function addChecklistStep() {
    if (!task) return;
    const text = newChecklistStepText.trim();
    const existingCommand =
      pendingChecklistAddCommandRef.current ??
      checklistAddOperations.get(task.id);
    if (!text && !existingCommand) return;
    const command = getOrCreateTaskChecklistAddCommand(
      existingCommand,
      task.id,
      text,
      generateUUID(),
    );
    pendingChecklistAddCommandRef.current = command;
    checklistAddOperations.set(command);
    setPendingChecklistAddCommand(command);
    void mutateChecklist(
      command.command,
      "Paso agregado.",
      command.operation_id,
    ).then((outcome) => {
      const settledCommand = settleTaskChecklistAddOperation(
        checklistAddOperations,
        pendingChecklistAddCommandRef.current,
        outcome,
      );
      pendingChecklistAddCommandRef.current = settledCommand;
      setPendingChecklistAddCommand(settledCommand);
      if (shouldClearTaskChecklistAddText(outcome)) {
        setNewChecklistStepText("");
      } else if (outcome === "unresolved") {
        setChecklistNotice(
          "No se pudo confirmar el paso. Reintenta esta misma alta antes de agregar otro.",
        );
      }
    });
  }

  function saveChecklistStep(stepId: string) {
    const step = baseTask?.steps.find((candidate) => candidate.id === stepId);
    const text = editingChecklistStepText.trim();
    if (!step || !text) return;
    void mutateChecklist(
      {
        action: "edit",
        step_id: step.id,
        text,
        expected_version: step.version,
      },
      "Paso actualizado.",
    ).then((outcome) => {
      if (outcome !== "confirmed") return;
      setEditingChecklistStepId(null);
      setEditingChecklistStepText("");
    });
  }

  function moveChecklistStep(stepId: string, offset: number) {
    if (!baseTask) return;
    const reordered = moveTaskChecklistStep(baseTask.steps, stepId, offset);
    if (
      reordered.every((step, index) => step.id === baseTask.steps[index]?.id)
    ) {
      return;
    }
    void mutateChecklist(
      {
        action: "reorder",
        step_ids: reordered.map((step) => step.id),
        expected_order_version: baseTask.steps_order_version,
      },
      "Orden actualizado.",
    );
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
    const dueOn = draft.due_on || null;
    if (dueOn !== baseTask.due_on) {
      updates.due_on = dueOn;
      expectedVersions.due_on = baseTask.field_versions.due_on;
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

    if (draft.due_on && !isDateOnly(draft.due_on)) {
      setDueOnError("Escribe una fecha válida.");
      return;
    }

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
      setDraftPreservationBaseVersions(result.task.field_versions);
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
        error.reason === "rejected" &&
        Object.hasOwn(operation.updates, "due_on")
      ) {
        setDueOnError(
          "No se pudo guardar esta fecha. Revísala e inténtalo de nuevo.",
        );
      }
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
      const dueOnDraft = draft.due_on || null;
      if (
        Object.hasOwn(expiredOperation.updates, "due_on") ||
        dueOnDraft !== latestTask.due_on
      ) {
        nextConflicts.due_on = {
          current: latestTask.due_on,
          draft: dueOnDraft,
          current_version: latestTask.field_versions.due_on,
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
    let nextDraft = draft;
    if (!keepDraft) {
      const currentValue = baseTask[field];
      nextDraft = {
        ...draft,
        [field]:
          field === "description" || field === "due_on"
            ? (currentValue ?? "")
            : currentValue,
      };
      updateDraft(nextDraft);
    }
    const nextBaseVersions = {
      ...(draftPreservationBaseVersions ?? baseTask.field_versions),
      [field]: baseTask.field_versions[field],
    };
    setDraftPreservationBaseVersions(nextBaseVersions);
    if (task) {
      onEditDraftChange(
        task.id,
        nextDraft,
        dirtyTaskEditFields(baseTask, nextDraft),
        nextBaseVersions,
      );
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
  const checklistProgress = getTaskChecklistProgress(baseTask.steps);

  return (
    <>
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

          <section
            className="border-border border-t pt-3"
            aria-labelledby="task-checklist-heading"
          >
            <div className="mb-3 flex items-center justify-between gap-3">
              <h3
                id="task-checklist-heading"
                className="font-semibold text-sm text-text-primary"
              >
                Pasos
              </h3>
              <span className="text-text-muted text-xs">
                {checklistProgress.completedCount}/
                {checklistProgress.totalCount}
              </span>
            </div>
            {baseTask.steps.length > 0 ? (
              <ol
                aria-label="Pasos de checklist"
                className="divide-y divide-border rounded-md border border-border"
              >
                {baseTask.steps.map((step, index) => (
                  <li
                    key={step.id}
                    className="flex flex-wrap items-center gap-2 p-3"
                  >
                    <input
                      id={`task-checklist-step-${step.id}`}
                      type="checkbox"
                      checked={step.is_completed}
                      disabled={!isOnline || isChecklistWorking}
                      onChange={(event) =>
                        void mutateChecklist(
                          {
                            action: "mark",
                            step_id: step.id,
                            is_completed: event.target.checked,
                            expected_version: step.version,
                          },
                          event.target.checked
                            ? "Paso marcado."
                            : "Paso desmarcado.",
                        )
                      }
                      aria-label={`${step.is_completed ? "Desmarcar" : "Marcar"} paso: ${step.text}`}
                      className="h-4 w-4 shrink-0 accent-emerald-400 disabled:opacity-50"
                    />
                    {editingChecklistStepId === step.id ? (
                      <input
                        value={editingChecklistStepText}
                        aria-label={`Editar paso: ${step.text}`}
                        disabled={isChecklistWorking}
                        onChange={(event) =>
                          setEditingChecklistStepText(event.target.value)
                        }
                        className="min-w-32 flex-1 rounded-md border border-border bg-transparent px-2 py-1 text-sm outline-none focus:border-accent"
                      />
                    ) : (
                      <label
                        htmlFor={`task-checklist-step-${step.id}`}
                        className={`min-w-32 flex-1 break-words text-sm ${step.is_completed ? "text-text-muted line-through" : "text-text-primary"}`}
                      >
                        {step.text}
                      </label>
                    )}
                    {editingChecklistStepId === step.id ? (
                      <>
                        <Button
                          type="button"
                          size="sm"
                          variant="ghost"
                          onClick={() => saveChecklistStep(step.id)}
                          disabled={
                            !isOnline ||
                            isChecklistWorking ||
                            !editingChecklistStepText.trim()
                          }
                        >
                          Guardar
                        </Button>
                        <Button
                          type="button"
                          size="sm"
                          variant="ghost"
                          onClick={() => {
                            setEditingChecklistStepId(null);
                            setEditingChecklistStepText("");
                          }}
                          disabled={isChecklistWorking}
                        >
                          Cancelar
                        </Button>
                      </>
                    ) : (
                      <>
                        <Button
                          type="button"
                          size="sm"
                          variant="ghost"
                          aria-label={`Subir paso: ${step.text}`}
                          onClick={() => moveChecklistStep(step.id, -1)}
                          disabled={
                            !isOnline || isChecklistWorking || index === 0
                          }
                        >
                          ↑
                        </Button>
                        <Button
                          type="button"
                          size="sm"
                          variant="ghost"
                          aria-label={`Bajar paso: ${step.text}`}
                          onClick={() => moveChecklistStep(step.id, 1)}
                          disabled={
                            !isOnline ||
                            isChecklistWorking ||
                            index === baseTask.steps.length - 1
                          }
                        >
                          ↓
                        </Button>
                        <Button
                          type="button"
                          size="sm"
                          variant="ghost"
                          onClick={() => {
                            setEditingChecklistStepId(step.id);
                            setEditingChecklistStepText(step.text);
                          }}
                          disabled={isChecklistWorking}
                        >
                          Editar
                        </Button>
                        <Button
                          type="button"
                          size="sm"
                          variant="ghost"
                          aria-label={`Eliminar paso: ${step.text}`}
                          onClick={() =>
                            void mutateChecklist(
                              {
                                action: "delete",
                                step_id: step.id,
                                expected_version: step.version,
                              },
                              "Paso eliminado. Puedes recuperarlo durante siete días.",
                            )
                          }
                          disabled={!isOnline || isChecklistWorking}
                        >
                          Eliminar
                        </Button>
                      </>
                    )}
                  </li>
                ))}
              </ol>
            ) : (
              <p className="mb-3 text-sm text-text-muted">
                Esta tarea todavía no tiene pasos.
              </p>
            )}
            <div className="mt-3 flex flex-col gap-2 sm:flex-row">
              <input
                value={newChecklistStepText}
                aria-label="Nuevo paso de checklist"
                placeholder="Agregar un paso"
                disabled={
                  !isOnline ||
                  isChecklistWorking ||
                  pendingChecklistAddCommand !== null
                }
                onChange={(event) =>
                  setNewChecklistStepText(event.target.value)
                }
                onKeyDown={(event) => {
                  if (event.key === "Enter") {
                    event.preventDefault();
                    addChecklistStep();
                  }
                }}
                className="min-h-10 min-w-0 flex-1 rounded-md border border-border bg-transparent px-3 text-sm outline-none focus:border-accent disabled:opacity-50"
              />
              <Button
                type="button"
                variant="ghost"
                onClick={addChecklistStep}
                disabled={
                  !isOnline ||
                  isChecklistWorking ||
                  (!pendingChecklistAddCommand && !newChecklistStepText.trim())
                }
              >
                {isChecklistWorking
                  ? "Guardando…"
                  : pendingChecklistAddCommand
                    ? "Reintentar alta"
                    : "Agregar paso"}
              </Button>
            </div>
            {checklistNotice ? (
              <output
                className="mt-2 block text-text-secondary text-xs"
                aria-live="polite"
              >
                {checklistNotice}
              </output>
            ) : null}
          </section>

          <section
            className="border-border border-t pt-3"
            aria-labelledby="task-assignee-heading"
          >
            <label
              id="task-assignee-heading"
              htmlFor="task-assignee"
              className="mb-2 block font-semibold text-text-muted text-xs"
            >
              Responsable actual (opcional)
            </label>
            <div className="flex flex-col gap-2 sm:flex-row">
              <select
                id="task-assignee"
                value={selectedAssigneeId}
                disabled={isWorking || !isOnline || !assignableMembers}
                onChange={(event) => {
                  setSelectedAssigneeId(event.target.value);
                  setAssigneeNotice("");
                }}
                className="h-11 min-w-0 flex-1 rounded-md border border-border bg-surface-base px-3 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-60"
              >
                <option value="">Sin responsable</option>
                {baseTask.assignee_id &&
                !assignableMembers?.some(
                  (member) => member.user_id === baseTask.assignee_id,
                ) ? (
                  <option value={baseTask.assignee_id} disabled>
                    Responsable actual no disponible
                  </option>
                ) : null}
                {assignableMembers?.map((member) => (
                  <option key={member.user_id} value={member.user_id}>
                    {member.name}
                    {member.name !== member.email ? ` · ${member.email}` : ""}
                    {member.role === "owner" ? " · propietario" : ""}
                  </option>
                ))}
              </select>
              <Button
                type="button"
                variant="ghost"
                onClick={() => void saveAssignee()}
                disabled={
                  isWorking ||
                  !isOnline ||
                  !assignableMembers ||
                  selectedAssigneeId === (baseTask.assignee_id ?? "")
                }
              >
                {isAssigning ? "Guardando…" : "Guardar responsable"}
              </Button>
            </div>
            {assigneeNotice ? (
              <output
                className="mt-2 block text-text-secondary text-xs"
                aria-live="polite"
              >
                {assigneeNotice}
              </output>
            ) : null}
            {assignableMembers === null ? (
              <output
                className="mt-2 block text-priority-medium text-xs"
                aria-live="polite"
              >
                No se pudieron cargar los miembros del tablero.
              </output>
            ) : null}
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
                <div className="flex flex-col gap-2 sm:col-span-2">
                  <label
                    htmlFor="task-due-on"
                    className="flex items-center gap-1.5 font-semibold text-text-muted text-xs"
                  >
                    <IconCalendar size={14} aria-hidden="true" /> Fecha límite
                    (opcional)
                  </label>
                  <input
                    id="task-due-on"
                    type="date"
                    value={draft.due_on}
                    disabled={isWorking}
                    aria-invalid={Boolean(dueOnError)}
                    aria-describedby={
                      dueOnError ? "task-due-on-error" : "task-due-on-help"
                    }
                    onChange={(event) =>
                      updateDraft({ ...draft, due_on: event.target.value })
                    }
                    className="h-11 w-full rounded-md border border-border bg-transparent px-3 py-2 text-sm text-text-primary outline-none transition-colors focus:border-accent focus:ring-1 focus:ring-accent disabled:opacity-60"
                  />
                  <p id="task-due-on-help" className="text-text-muted text-xs">
                    Sin hora · Zona del tablero: {boardTimeZone}
                  </p>
                  {dueOnError && (
                    <p
                      id="task-due-on-error"
                      className="text-priority-urgent text-xs"
                      role="alert"
                    >
                      {dueOnError}
                    </p>
                  )}
                  {draft.due_on && (
                    <TaskDueDate
                      dueOn={draft.due_on}
                      boardToday={boardToday}
                      isCompleted={baseTask.is_completed}
                    />
                  )}
                </div>
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

          <TaskConversation
            slug={slug}
            taskId={baseTask.id}
            actorId={actorId}
            role={role}
            initialCommentId={initialCommentId}
            assignableMembers={assignableMembers}
            operations={commentOperations}
            isOnline={isOnline}
            isSessionStale={isSessionStale}
            onAccessLost={onConversationAccessLost}
          />

          {!isOnline && (
            <output
              aria-live="polite"
              className="rounded-md border border-priority-medium/30 bg-priority-medium/10 p-3 text-priority-medium text-sm"
            >
              Estás sin conexión. El borrador queda solo en esta pantalla y no
              se enviará automáticamente al reconectar.
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
                El borrador vive solo en esta sesión y no se recupera si
                recargas o cierras la página.
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
                  La tarea solo se moverá si confirmas el guardado o descartas
                  el borrador. Si guardar falla o hay un conflicto, el
                  movimiento se detiene y podrás revisar el estado actual.
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
      <ConfirmDialog
        open={pendingChecklistReview !== null}
        onClose={cancelChecklistCompletionReview}
        onConfirm={acceptChecklistCompletionReview}
        title="Completar tarea con pasos pendientes"
        description={
          pendingChecklistReview
            ? pendingChecklistReview.pendingStepsCount === 1
              ? "Queda 1 paso sin marcar. ¿Completar igual?"
              : `Quedan ${pendingChecklistReview.pendingStepsCount} pasos sin marcar. ¿Completar igual?`
            : ""
        }
        confirmLabel="Completar igual"
        cancelLabel="Cancelar"
        loading={isCompleting}
      />
    </>
  );
}
