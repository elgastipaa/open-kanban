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
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { useBoard } from "@/hooks/use-board";
import { useDevice } from "@/hooks/use-device";
import { useHotKeys } from "@/hooks/use-hotkeys";
import { useOnlineStatus } from "@/hooks/use-online-status";
import { usePresence } from "@/hooks/use-presence";
import { useRealtime } from "@/hooks/use-realtime";
import { resolveApplicationAccess } from "@/lib/auth";
import { exportBoard } from "@/lib/export";
import { importBoard } from "@/lib/import";
import {
  abortPendingSessionRequests,
  createClient,
} from "@/lib/supabase/client";
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
  Board as BoardType,
  ColumnWithTasks,
  Task,
  TaskOrderResult,
} from "@/lib/types";
import { generateUUID } from "@/lib/utils";

interface BoardProps {
  slug: string;
  initialBoard: BoardType;
  initialColumns: ColumnWithTasks[];
  ownerAuthUserId: string;
}

type BoardWorkspaceProps = Omit<BoardProps, "ownerAuthUserId"> & {
  isSessionStale: boolean;
  onAccessLost: () => void;
};

type SessionStatus = "checking" | "active" | "stale" | "denied";

export function Board({
  slug,
  initialBoard,
  initialColumns,
  ownerAuthUserId,
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
      initialBoard={initialBoard}
      initialColumns={initialColumns}
      isSessionStale={sessionStatus === "stale"}
      onAccessLost={onAccessLost}
    />
  );
}

function BoardWorkspace({
  slug,
  initialBoard,
  initialColumns,
  isSessionStale,
  onAccessLost,
}: BoardWorkspaceProps) {
  const router = useRouter();
  const { isMobile, isReady } = useDevice();
  const [openColumnFormSignal, setOpenColumnFormSignal] = useState(0);

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
    refreshTaskForEdit,
    removeTask,
    moveTask,
    moveColumn,
    removeBoard,
    replaceState,
    refreshFromDB,
  } = useBoard({
    slug,
    initialBoard,
    initialColumns,
    onMutation: broadcastSync,
    onAccessLost,
  });

  // Wire the refs after useBoard returns
  refreshRef.current = refreshFromDB;
  replaceStateRef.current = replaceState;

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

  async function handleCardCompletion(task: Task, isCompleted: boolean) {
    try {
      const result = await completeTask({
        id: task.id,
        operation_id: generateUUID(),
        is_completed: isCompleted,
        expected_version: task.completion_version,
      });
      if (result.status === "confirmed") {
        toast.success(isCompleted ? "Tarea completada" : "Tarea reabierta");
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
    } catch {
      toast.error("No se pudo confirmar el cambio de estado", {
        description: "Revisa el tablero antes de volver a elegir la acción.",
      });
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
    if (!previousFlow.waitingForEditorCloseTaskId) restoreTaskFocus();
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
        name={board?.name ?? initialBoard.name}
        canRename={initialBoard.role === "owner"}
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
        columns={columns}
        contextLabel={`${board?.name ?? initialBoard.name} · ${taskOriginRef.current?.columnTitle ?? "Columna"}`}
        open={editingTaskId !== null && editingTask !== null}
        isOnline={isOnline}
        onClose={() => setEditingTaskId(null)}
        onAfterClose={handleTaskEditorAfterClose}
        onReconcileTask={refreshTaskForEdit}
        onSave={editTask}
        onSetTaskCompletion={completeTask}
        onMoveTask={moveTaskFromEditor}
        onDelete={handleRequestEditorTaskDelete}
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
        title="Delete Task"
        description="Are you sure you want to delete this task? This action cannot be undone."
        confirmLabel="Delete Task"
      />
    </div>
  );
}
