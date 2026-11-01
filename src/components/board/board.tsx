"use client";

import { DragDropContext, type DropResult } from "@hello-pangea/dnd";
import type { AuthChangeEvent, Session } from "@supabase/supabase-js";
import { LayoutGroup } from "motion/react";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { toast } from "sonner";
import { AddColumn } from "@/components/board/add-column";
import { BoardToolbar } from "@/components/board/board-toolbar";
import { Column } from "@/components/board/column";
import { KeyboardShortcuts } from "@/components/board/keyboard-shortcuts";
import { MobileBoard } from "@/components/board/mobile-board";
import { TaskModal } from "@/components/board/task-modal";
import { TaskRecoveryDialog } from "@/components/board/task-recovery-dialog";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { useBoard } from "@/hooks/use-board";
import { useDevice } from "@/hooks/use-device";
import { useHotKeys } from "@/hooks/use-hotkeys";
import { useOnlineStatus } from "@/hooks/use-online-status";
import { usePresence } from "@/hooks/use-presence";
import { useRealtime } from "@/hooks/use-realtime";
import { resolveApplicationAccess } from "@/lib/auth";
import { previewBoardTimeZone, updateBoardTimeZone } from "@/lib/db/boards";
import { setTaskAssignee, TaskAssigneeError } from "@/lib/db/my-tasks";
import { exportBoard } from "@/lib/export";
import { importBoard } from "@/lib/import";
import {
  abortPendingSessionRequests,
  createClient,
} from "@/lib/supabase/client";
import { resolveTaskChecklistCompletionReview } from "@/lib/task-checklist-completion";
import {
  getTaskChecklistCompletionReview,
  type TaskChecklistCompletionReview,
} from "@/lib/task-checklist-state";
import { TaskCommentCreateOperationStore } from "@/lib/task-comments-state";
import { pendingTaskInsertionIndex } from "@/lib/task-completion";
import {
  cancelTaskDelete,
  confirmTaskDelete,
  createTaskDeleteFlow,
  finishTaskDeleteDialogClose,
  finishTaskEditorClose,
  requestCardTaskDelete,
  requestEditorTaskDelete,
  type TaskDeleteFlow,
} from "@/lib/task-delete-flow";
import {
  captureTaskFocusOrigin,
  selectTaskFocusTarget,
  type TaskFocusOrigin,
} from "@/lib/task-edit-focus";
import type {
  AssignableBoardMember,
  Board as BoardType,
  ColumnWithTasks,
  Task,
  TaskAssigneeCommand,
  TaskAssigneeResult,
  TaskCompletionCommand,
  TaskCompletionResult,
  TaskOrderResult,
} from "@/lib/types";
import { generateUUID } from "@/lib/utils";

interface BoardProps {
  slug: string;
  initialBoard: BoardType;
  initialColumns: ColumnWithTasks[];
  ownerAuthUserId: string;
  assignableMembers: AssignableBoardMember[] | null;
  hasOtherCurrentMembers: boolean | null;
  initialTaskId: string | null;
  initialCommentId: string | null;
  myTasksReturnHref: string | null;
}

type BoardWorkspaceProps = Omit<BoardProps, "ownerAuthUserId"> & {
  actorId: string;
  isSessionStale: boolean;
  onAccessLost: () => void;
};

type SessionStatus = "checking" | "active" | "stale" | "denied";

export function Board({
  slug,
  initialBoard,
  initialColumns,
  ownerAuthUserId,
  assignableMembers,
  hasOtherCurrentMembers,
  initialTaskId,
  initialCommentId,
  myTasksReturnHref,
}: BoardProps) {
  const router = useRouter();
  const [sessionStatus, setSessionStatus] = useState<SessionStatus>("checking");
  const onAccessLost = useCallback(() => {
    abortPendingSessionRequests();
    setSessionStatus("denied");
    router.replace("/");
  }, [router]);

  useEffect(() => {
    let disposed = false;
    let checking = false;
    let denied = false;
    let verificationGeneration = 0;
    const supabase = createClient();

    const denySession = () => {
      if (disposed || denied) return;
      denied = true;
      verificationGeneration += 1;
      abortPendingSessionRequests();
      setSessionStatus("denied");
      router.replace("/");
    };

    const preserveSessionData = () => {
      if (!disposed && !denied) setSessionStatus("stale");
    };

    const verifySession = async () => {
      if (disposed || checking || denied) return;
      checking = true;
      const generation = ++verificationGeneration;
      try {
        const { data, error } = await supabase.auth.getUser();
        if (error) {
          preserveSessionData();
          return;
        }
        if (!data.user || data.user.id !== ownerAuthUserId) {
          denySession();
          return;
        }

        const access = await resolveApplicationAccess(supabase);
        if (access.status === "error") {
          preserveSessionData();
          return;
        }
        if (access.status !== "active") {
          denySession();
          return;
        }

        const { data: boardAccess, error: boardAccessError } = await supabase
          .rpc("get_board_p", { p_slug: slug })
          .maybeSingle();
        if (boardAccessError) {
          preserveSessionData();
          return;
        }
        if (!boardAccess) {
          denySession();
          return;
        }

        if (!disposed && generation === verificationGeneration) {
          setSessionStatus("active");
        }
      } catch {
        preserveSessionData();
      } finally {
        checking = false;
      }
    };

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange(
      (_event: AuthChangeEvent, session: Session | null) => {
        if (!session || session.user.id !== ownerAuthUserId) {
          denySession();
          return;
        }
        window.setTimeout(() => void verifySession(), 0);
      },
    );

    const onFocus = () => void verifySession();
    const onVisibilityChange = () => {
      if (document.visibilityState === "visible") void verifySession();
    };

    void verifySession();
    const interval = window.setInterval(() => {
      if (document.visibilityState === "visible") void verifySession();
    }, 30_000);
    window.addEventListener("focus", onFocus);
    document.addEventListener("visibilitychange", onVisibilityChange);

    return () => {
      disposed = true;
      subscription.unsubscribe();
      window.clearInterval(interval);
      window.removeEventListener("focus", onFocus);
      document.removeEventListener("visibilitychange", onVisibilityChange);
    };
  }, [ownerAuthUserId, router, slug]);

  if (sessionStatus === "checking" || sessionStatus === "denied") {
    return (
      <output
        className="flex h-dvh items-center justify-center bg-surface-base"
        aria-live="polite"
      >
        <span className="sr-only">Verificando el acceso al tablero…</span>
        <span className="board-spinner block" aria-hidden="true" />
      </output>
    );
  }

  return (
    <BoardWorkspace
      slug={slug}
      actorId={ownerAuthUserId}
      initialBoard={initialBoard}
      initialColumns={initialColumns}
      assignableMembers={assignableMembers}
      hasOtherCurrentMembers={hasOtherCurrentMembers}
      initialTaskId={initialTaskId}
      initialCommentId={initialCommentId}
      myTasksReturnHref={myTasksReturnHref}
      isSessionStale={sessionStatus === "stale"}
      onAccessLost={onAccessLost}
    />
  );
}

function BoardWorkspace({
  slug,
  actorId,
  initialBoard,
  initialColumns,
  assignableMembers,
  hasOtherCurrentMembers,
  initialTaskId,
  initialCommentId,
  myTasksReturnHref,
  isSessionStale,
  onAccessLost,
}: BoardWorkspaceProps) {
  const router = useRouter();
  const { isMobile, isReady } = useDevice();
  const [openColumnFormSignal, setOpenColumnFormSignal] = useState(0);
  const taskCommentOperations = useMemo(
    () => new TaskCommentCreateOperationStore(actorId, slug),
    [actorId, slug],
  );
  const currentMemberNames = useMemo(
    () =>
      Object.fromEntries(
        (assignableMembers ?? []).map((member) => [
          member.user_id,
          member.name,
        ]),
      ),
    [assignableMembers],
  );

  // Ref to hold refreshFromDB - avoids circular dependency between hooks
  const refreshRef = useRef<(() => Promise<void>) | undefined>(undefined);

  // Ref to hold replaceState - avoids circular dependency between hooks
  const replaceStateRef = useRef<
    ((newBoard: null, newColumns: []) => void) | undefined
  >(undefined);

  // Realtime: broadcast sync after every mutation, refetch on incoming sync
  const { broadcastSync, broadcastBoardDeleted } = useRealtime({
    boardId: initialBoard.id,
    onSync: () => {
      refreshRef.current?.();
    },
    onBoardDeleted: () => {
      toast.error("Board deleted", {
        description: "Another user has deleted this board.",
      });
      replaceStateRef.current?.(null, []); // This resets the board to initial To Do state
      router.push("/");
    },
  });

  const {
    board,
    columns,
    addColumn,
    renameColumn,
    toggleColumnCollapse,
    toggleAllColumnsCollapse,
    removeColumn,
    addTask,
    editTask,
    completeTask,
    mutateChecklistStep,
    checklistAddOperations,
    refreshTaskForEdit,
    refreshBoardFromDB,
    applyBoardSettings,
    removeTask,
    moveTask,
    moveColumn,
    removeBoard,
    replaceState,
    refreshFromDB,
  } = useBoard({
    actorId,
    slug,
    initialBoard,
    initialColumns,
    onMutation: broadcastSync,
    onAccessLost,
  });

  // Wire the refs after useBoard returns
  refreshRef.current = refreshFromDB;
  replaceStateRef.current = replaceState;

  useEffect(() => {
    const refreshBoardDay = () => {
      if (document.visibilityState === "visible") {
        void refreshBoardFromDB().catch(() => undefined);
      }
    };
    const onVisibilityChange = () => refreshBoardDay();
    const interval = window.setInterval(refreshBoardDay, 30_000);
    window.addEventListener("focus", refreshBoardDay);
    document.addEventListener("visibilitychange", onVisibilityChange);
    return () => {
      window.clearInterval(interval);
      window.removeEventListener("focus", refreshBoardDay);
      document.removeEventListener("visibilitychange", onVisibilityChange);
    };
  }, [refreshBoardFromDB]);

  // Keyboard shortcuts (desktop only)
  const hotKeyBindings = useMemo(
    () => [
      {
        key: "j",
        ctrlOrCmd: true,
        action: () => setOpenColumnFormSignal((signal) => signal + 1),
      },
      {
        key: "ArrowUp",
        ctrlOrCmd: true,
        action: () => toggleAllColumnsCollapse(false),
      },
      {
        key: "ArrowDown",
        ctrlOrCmd: true,
        action: () => toggleAllColumnsCollapse(true),
      },
    ],
    [toggleAllColumnsCollapse],
  );
  useHotKeys(hotKeyBindings);

  // Presence
  const { viewerCount, isConnected } = usePresence(initialBoard.id);

  // Task modal state
  const [editingTaskId, setEditingTaskId] = useState<string | null>(null);
  const [pendingCardCompletionReview, setPendingCardCompletionReview] =
    useState<{
      command: TaskCompletionCommand;
      review: TaskChecklistCompletionReview;
    } | null>(null);
  const [isConfirmingCardCompletion, setIsConfirmingCardCompletion] =
    useState(false);
  const taskOriginRef = useRef<TaskFocusOrigin | null>(null);
  const { isOnline } = useOnlineStatus();
  const editingTask = editingTaskId
    ? (columns
        .flatMap((column) => column.tasks)
        .find((task) => task.id === editingTaskId) ?? null)
    : null;

  useEffect(() => {
    if (editingTaskId && !editingTask) setEditingTaskId(null);
  }, [editingTask, editingTaskId]);

  function openTaskDetail(task: Task) {
    taskOriginRef.current = captureTaskFocusOrigin(
      task.id,
      task.column_id,
      columns.map((column) => ({
        id: column.id,
        title: column.title,
        taskIds: column.tasks.map((candidate) => candidate.id),
      })),
    );
    setEditingTaskId(task.id);
  }

  const initialTaskOpenedRef = useRef(false);
  useEffect(() => {
    if (initialTaskOpenedRef.current || !initialTaskId) return;
    const task = columns
      .flatMap((column) => column.tasks)
      .find((candidate) => candidate.id === initialTaskId);
    if (!task) return;
    initialTaskOpenedRef.current = true;
    taskOriginRef.current = captureTaskFocusOrigin(
      task.id,
      task.column_id,
      columns.map((column) => ({
        id: column.id,
        title: column.title,
        taskIds: column.tasks.map((candidate) => candidate.id),
      })),
    );
    setEditingTaskId(task.id);
  }, [columns, initialTaskId]);

  async function assignTask(
    command: TaskAssigneeCommand,
  ): Promise<TaskAssigneeResult> {
    try {
      const result = await setTaskAssignee(createClient(), slug, command);
      if (result.status === "confirmed" || result.status === "conflict") {
        await refreshBoardFromDB().catch(() => undefined);
        broadcastSync();
      }
      return result;
    } catch (error) {
      if (
        error instanceof TaskAssigneeError &&
        error.reason === "access_denied"
      ) {
        onAccessLost();
      }
      throw error;
    }
  }

  const moveTaskFromEditor = useCallback(
    (
      taskId: string,
      destinationColumnId: string,
    ): Promise<TaskOrderResult | null> => {
      const sourceColumn = columns.find((column) =>
        column.tasks.some((task) => task.id === taskId),
      );
      const destinationColumn = columns.find(
        (column) => column.id === destinationColumnId,
      );
      if (!sourceColumn || !destinationColumn) return Promise.resolve(null);
      const sourceIndex = sourceColumn.tasks.findIndex(
        (task) => task.id === taskId,
      );
      if (sourceIndex === -1) return Promise.resolve(null);
      return moveTask(
        sourceColumn.id,
        destinationColumn.id,
        sourceIndex,
        destinationColumn.tasks.length,
      );
    },
    [columns, moveTask],
  );

  function restoreTaskFocus() {
    const origin = taskOriginRef.current;
    const triggers = Array.from(
      document.querySelectorAll<HTMLButtonElement>("[data-task-trigger]"),
    );
    const target = selectTaskFocusTarget(
      origin,
      triggers.flatMap((element) => {
        const taskId = element.dataset.taskTrigger;
        const columnId = element.dataset.taskColumn;
        const position = Number(element.dataset.taskIndex);
        return taskId && columnId && Number.isFinite(position)
          ? [{ taskId, columnId, position }]
          : [];
      }),
      Array.from(
        document.querySelectorAll<HTMLElement>("[data-column-focus]"),
      ).flatMap((element) =>
        element.dataset.columnFocus ? [element.dataset.columnFocus] : [],
      ),
      Boolean(document.querySelector("[data-board-focus]")),
    );
    const focusTarget =
      target?.kind === "task"
        ? triggers.find(
            (element) =>
              element.dataset.taskTrigger === target.taskId &&
              element.dataset.taskColumn === target.columnId,
          )
        : target?.kind === "column"
          ? Array.from(
              document.querySelectorAll<HTMLElement>("[data-column-focus]"),
            ).find((element) => element.dataset.columnFocus === target.columnId)
          : target?.kind === "board"
            ? document.querySelector<HTMLElement>("[data-board-focus]")
            : null;
    if (focusTarget?.isConnected) {
      focusTarget.scrollIntoView({ block: "nearest" });
      focusTarget.focus({ preventScroll: true });
    }
  }

  // Delete board confirmation
  const [showDeleteBoard, setShowDeleteBoard] = useState(false);
  const [isDeletingBoard, setIsDeletingBoard] = useState(false);
  const [isTaskRecoveryDialogOpen, setIsTaskRecoveryDialogOpen] =
    useState(false);

  // Delete column confirmation
  const [deletingColumnId, setDeletingColumnId] = useState<string | null>(null);

  // Delete task confirmation
  const [taskDeleteFlow, setTaskDeleteFlow] =
    useState<TaskDeleteFlow>(createTaskDeleteFlow);
  const taskDeleteFlowRef = useRef(taskDeleteFlow);

  function storeTaskDeleteFlow(nextFlow: TaskDeleteFlow) {
    taskDeleteFlowRef.current = nextFlow;
    setTaskDeleteFlow(nextFlow);
  }

  // Drag & drop handler (desktop only)
  const onDragEnd = useCallback(
    (result: DropResult) => {
      const { source, destination } = result;
      if (!destination) return;
      if (
        source.droppableId === destination.droppableId &&
        source.index === destination.index
      ) {
        return;
      }
      const sourceColumn = columns.find(
        (column) => column.id === source.droppableId,
      );
      const destinationColumn = columns.find(
        (column) => column.id === destination.droppableId,
      );
      if (!sourceColumn || !destinationColumn) return;
      const sourceIndex = sourceColumn.tasks.findIndex(
        (task) => task.id === result.draggableId,
      );
      const sourceTask = sourceColumn.tasks[sourceIndex];
      if (sourceIndex < 0 || !sourceTask || sourceTask.is_completed) return;

      const destinationAfterRemoval =
        sourceColumn.id === destinationColumn.id
          ? destinationColumn.tasks.filter(
              (task) => task.id !== result.draggableId,
            )
          : destinationColumn.tasks;
      const destinationIndex = pendingTaskInsertionIndex(
        destinationAfterRemoval,
        destination.index,
      );
      moveTask(
        source.droppableId,
        destination.droppableId,
        sourceIndex,
        destinationIndex,
      );
    },
    [columns, moveTask],
  );

  function reportCardCompletion(result: TaskCompletionResult) {
    if (result.status === "confirmed") {
      toast.success(
        result.task.is_completed ? "Tarea completada" : "Tarea reabierta",
      );
    } else if (result.status === "conflict") {
      toast.error("El estado de la tarea cambió", {
        description:
          "Actualizamos el tablero. Abre la tarea y elige de nuevo la acción.",
      });
    } else {
      toast.error("No se pudo confirmar el cambio de estado", {
        description: "Revisa el tablero antes de volver a elegir la acción.",
      });
    }
  }

  async function handleCardCompletion(task: Task, isCompleted: boolean) {
    const command: TaskCompletionCommand = {
      id: task.id,
      operation_id: generateUUID(),
      is_completed: isCompleted,
      expected_version: task.completion_version,
    };
    try {
      const result = await completeTask(command);
      const review = getTaskChecklistCompletionReview(result);
      if (review) {
        setPendingCardCompletionReview({ command, review });
        return;
      }
      reportCardCompletion(result);
    } catch {
      toast.error("No se pudo confirmar el cambio de estado", {
        description: "Revisa el tablero antes de volver a elegir la acción.",
      });
    }
  }

  async function acceptCardCompletionReview() {
    if (!pendingCardCompletionReview || isConfirmingCardCompletion) return;
    const command = resolveTaskChecklistCompletionReview(
      pendingCardCompletionReview.command,
      pendingCardCompletionReview.review,
      "accept",
    );
    if (!command) {
      setPendingCardCompletionReview(null);
      return;
    }
    setIsConfirmingCardCompletion(true);
    try {
      const result = await completeTask(command);
      const refreshedReview = getTaskChecklistCompletionReview(result);
      if (refreshedReview) {
        setPendingCardCompletionReview({ command, review: refreshedReview });
        return;
      }
      setPendingCardCompletionReview(null);
      reportCardCompletion(result);
    } catch {
      toast.error("No se pudo confirmar el cambio de estado", {
        description: "Revisa el tablero antes de volver a elegir la acción.",
      });
    } finally {
      setIsConfirmingCardCompletion(false);
    }
  }

  // Board delete handler
  async function handleDeleteBoard() {
    setIsDeletingBoard(true);
    try {
      const deleted = await removeBoard();
      if (!deleted) return;
      // Notify other users looking at this board
      broadcastBoardDeleted();
      router.push("/");
    } finally {
      setIsDeletingBoard(false);
      setShowDeleteBoard(false);
    }
  }

  async function handlePreviewTimeZone(timeZone: string) {
    return previewBoardTimeZone(createClient(), slug, timeZone);
  }

  async function handleSaveTimeZone(
    expectedTimeZone: string,
    timeZone: string,
  ) {
    const updatedBoard = await updateBoardTimeZone(
      createClient(),
      slug,
      expectedTimeZone,
      timeZone,
    );
    applyBoardSettings(updatedBoard);
    broadcastSync();
  }

  // Column delete handler (optimistic: close dialog instantly, removeColumn handles rollback)
  function handleDeleteColumn() {
    if (!deletingColumnId) return;
    const columnId = deletingColumnId;
    setDeletingColumnId(null);
    removeColumn(columnId);
  }

  // Task delete handler
  function handleDeleteTask() {
    const taskId = taskDeleteFlow.deletingTaskId;
    if (!taskId) return;
    removeTask(taskId);
    // Close modal if the deleted task was being edited
    if (editingTaskId === taskId) {
      setEditingTaskId(null);
    }
    storeTaskDeleteFlow(confirmTaskDelete(taskDeleteFlowRef.current));
  }

  // Request task deletion (opens confirmation dialog)
  function requestDeleteTask(taskId: string) {
    storeTaskDeleteFlow(
      requestCardTaskDelete(taskDeleteFlowRef.current, taskId),
    );
  }

  function handleRequestEditorTaskDelete(taskId: string) {
    storeTaskDeleteFlow(
      requestEditorTaskDelete(taskDeleteFlowRef.current, taskId),
    );
    setEditingTaskId(null);
  }

  function handleTaskEditorAfterClose() {
    const previousFlow = taskDeleteFlowRef.current;
    storeTaskDeleteFlow(finishTaskEditorClose(previousFlow));
    if (!myTasksReturnHref && !previousFlow.waitingForEditorCloseTaskId) {
      restoreTaskFocus();
    }
  }

  function handleCancelTaskDelete() {
    const taskId = taskDeleteFlowRef.current.deletingTaskId;
    const taskStillExists = Boolean(
      taskId &&
        columns.some((column) =>
          column.tasks.some((task) => task.id === taskId),
        ),
    );
    const result = cancelTaskDelete(taskDeleteFlowRef.current, taskStillExists);
    storeTaskDeleteFlow(result.flow);
    if (result.reopenEditorTaskId) {
      setEditingTaskId(result.reopenEditorTaskId);
    }
  }

  function handleTaskDeleteDialogAfterClose() {
    const result = finishTaskDeleteDialogClose(taskDeleteFlowRef.current);
    storeTaskDeleteFlow(result.flow);
    if (result.restoreTaskFocus) restoreTaskFocus();
  }

  // Export handler
  function handleExport() {
    try {
      exportBoard(slug, columns);
      toast.success("Board exported successfully");
    } catch {
      toast.error("Export failed", {
        description: "Could not export the board. Please try again.",
      });
    }
  }

  // Import handler
  async function handleImport() {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = ".json";
    input.onchange = async (e) => {
      const file = (e.target as HTMLInputElement).files?.[0];
      if (!file) return;
      try {
        await importBoard(file, slug);
        await refreshFromDB();
        broadcastSync();
        toast.success("Board imported successfully");
      } catch (err) {
        toast.error("Import failed", {
          description:
            err instanceof Error ? err.message : "Invalid file format.",
        });
      }
    };
    input.click();
  }

  return (
    <div
      data-board-focus
      tabIndex={-1}
      className="flex h-dvh flex-col bg-surface-base"
    >
      {isSessionStale && (
        <output
          className="block border-border border-b bg-surface-raised px-4 py-2 text-center text-priority-medium text-sm"
          aria-live="polite"
        >
          No se pudo confirmar el acceso. Se muestran los últimos datos
          cargados; verifica tu conexión.
        </output>
      )}
      <BoardToolbar
        slug={slug}
        myTasksReturnHref={myTasksReturnHref}
        name={board?.name ?? initialBoard.name}
        timeZone={board?.time_zone ?? initialBoard.time_zone}
        canRename={board?.role === "owner"}
        memberRole={initialBoard.role}
        boardId={initialBoard.id}
        actorId={actorId}
        hasOtherCurrentMembers={hasOtherCurrentMembers}
        eligibleSuccessors={assignableMembers}
        canRecoverTasks={
          initialBoard.role === "owner" || initialBoard.role === "collaborator"
        }
        onOpenTaskRecovery={() => setIsTaskRecoveryDialogOpen(true)}
        onPreviewTimeZone={handlePreviewTimeZone}
        onSaveTimeZone={handleSaveTimeZone}
        viewerCount={viewerCount}
        isConnected={isConnected}
        onDeleteBoard={() => setShowDeleteBoard(true)}
        onExport={handleExport}
        onImport={handleImport}
      />

      {!isReady ? (
        /* ── Loading: device detection in progress ── */
        <div className="flex flex-1 items-center justify-center">
          <div className="board-spinner" />
        </div>
      ) : columns.length === 0 ? (
        <section className="flex flex-1 flex-col items-center justify-center gap-4 px-6 text-center">
          <div>
            <h2 className="font-semibold text-lg text-text-primary">
              Este tablero todavía no tiene columnas
            </h2>
            <p className="mt-2 max-w-sm text-sm text-text-muted">
              Elige los nombres y el orden que te sirvan para organizar tus
              tareas.
            </p>
          </div>
          <AddColumn
            variant="empty"
            onAdd={addColumn}
            openSignal={openColumnFormSignal}
          />
        </section>
      ) : isMobile ? (
        /* ── Mobile: single-column view ── */
        <MobileBoard
          columns={columns}
          boardToday={board?.today ?? initialBoard.today}
          currentMemberNames={currentMemberNames}
          onAddColumn={addColumn}
          onRenameColumn={renameColumn}
          onShiftColumn={moveColumn}
          onAddTask={addTask}
          onEditTask={openTaskDetail}
          onDeleteTask={requestDeleteTask}
          onCompleteTask={handleCardCompletion}
          onMoveTask={moveTask}
          onRequestDeleteColumn={(colId) => setDeletingColumnId(colId)}
        />
      ) : (
        /* ── Desktop: horizontal scrolling multi-column view ── */
        <DragDropContext onDragEnd={onDragEnd}>
          <LayoutGroup>
            <div className="board-scroll flex flex-1 gap-4 overflow-x-auto p-4 md:p-6">
              {columns.map((column, index) => (
                <Column
                  key={column.id}
                  column={column}
                  boardToday={board?.today ?? initialBoard.today}
                  currentMemberNames={currentMemberNames}
                  canDelete
                  canShiftLeft={index > 0}
                  canShiftRight={index < columns.length - 1}
                  onRenameColumn={renameColumn}
                  onToggleCollapse={toggleColumnCollapse}
                  onDeleteColumn={(colId) => setDeletingColumnId(colId)}
                  onShiftLeft={() => moveColumn(index, index - 1)}
                  onShiftRight={() => moveColumn(index, index + 1)}
                  onAddTask={addTask}
                  onEditTask={openTaskDetail}
                  onDeleteTask={requestDeleteTask}
                  onCompleteTask={handleCardCompletion}
                  onMoveTask={moveTask}
                />
              ))}
              <AddColumn onAdd={addColumn} openSignal={openColumnFormSignal} />
            </div>
          </LayoutGroup>
          <KeyboardShortcuts />
        </DragDropContext>
      )}

      {/* Task edit modal */}
      <TaskModal
        key={editingTask?.id ?? "closed"}
        task={editingTask}
        slug={slug}
        actorId={actorId}
        role={board?.role ?? initialBoard.role}
        initialCommentId={
          editingTaskId === initialTaskId ? initialCommentId : null
        }
        commentOperations={taskCommentOperations}
        isSessionStale={isSessionStale}
        onConversationAccessLost={onAccessLost}
        boardTimeZone={board?.time_zone ?? initialBoard.time_zone}
        boardToday={board?.today ?? initialBoard.today}
        columns={columns}
        contextLabel={`${board?.name ?? initialBoard.name} · ${taskOriginRef.current?.columnTitle ?? "Columna"} · ${board?.time_zone ?? initialBoard.time_zone}`}
        open={editingTaskId !== null && editingTask !== null}
        isOnline={isOnline}
        onClose={() => {
          setEditingTaskId(null);
          if (myTasksReturnHref) router.push(myTasksReturnHref);
          else if (initialCommentId) router.replace(`/${slug}`);
        }}
        onAfterClose={handleTaskEditorAfterClose}
        onReconcileTask={refreshTaskForEdit}
        onSave={editTask}
        onSetTaskCompletion={completeTask}
        checklistAddOperations={checklistAddOperations}
        onMutateChecklist={mutateChecklistStep}
        assignableMembers={assignableMembers}
        onSetTaskAssignee={assignTask}
        onMoveTask={moveTaskFromEditor}
        onDelete={handleRequestEditorTaskDelete}
      />

      <TaskRecoveryDialog
        open={isTaskRecoveryDialogOpen}
        onClose={() => setIsTaskRecoveryDialogOpen(false)}
        onRestored={async () => {
          await refreshBoardFromDB();
          broadcastSync();
        }}
        slug={slug}
        timeZone={board?.time_zone ?? initialBoard.time_zone}
        columns={columns.map((column) => ({
          id: column.id,
          title: column.title,
        }))}
      />

      <ConfirmDialog
        open={pendingCardCompletionReview !== null}
        onClose={() => setPendingCardCompletionReview(null)}
        onConfirm={acceptCardCompletionReview}
        title="Completar tarea con pasos pendientes"
        description={
          pendingCardCompletionReview
            ? pendingCardCompletionReview.review.pendingStepsCount === 1
              ? "Queda 1 paso sin marcar. ¿Completar igual?"
              : `Quedan ${pendingCardCompletionReview.review.pendingStepsCount} pasos sin marcar. ¿Completar igual?`
            : ""
        }
        confirmLabel="Completar igual"
        cancelLabel="Cancelar"
        loading={isConfirmingCardCompletion}
      />

      {/* Delete board confirmation */}
      <ConfirmDialog
        open={showDeleteBoard}
        onClose={() => setShowDeleteBoard(false)}
        onConfirm={handleDeleteBoard}
        title="Delete Board"
        description={`Are you sure you want to delete the board "/${slug}"? This will permanently remove all columns and tasks. This action cannot be undone.`}
        confirmLabel="Delete Board"
        loading={isDeletingBoard}
      />

      {/* Delete column confirmation */}
      <ConfirmDialog
        open={deletingColumnId !== null}
        onClose={() => setDeletingColumnId(null)}
        onConfirm={handleDeleteColumn}
        title="Delete Column"
        description="Are you sure you want to delete this column? All tasks in this column will be permanently removed."
        confirmLabel="Delete Column"
      />

      {/* Delete task confirmation */}
      <ConfirmDialog
        open={taskDeleteFlow.deletingTaskId !== null}
        onClose={handleCancelTaskDelete}
        onConfirm={handleDeleteTask}
        onAfterClose={handleTaskDeleteDialogAfterClose}
        title="Eliminar tarea"
        description="La tarea se podrá recuperar desde Opciones del tablero durante siete días (7 × 24 horas). Después no se podrá recuperar."
        confirmLabel="Eliminar tarea"
      />
    </div>
  );
}
