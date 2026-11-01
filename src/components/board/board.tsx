"use client";

import { DragDropContext, type DropResult } from "@hello-pangea/dnd";
import type { AuthChangeEvent, Session } from "@supabase/supabase-js";
import { LayoutGroup } from "motion/react";
import { useRouter } from "next/navigation";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { toast } from "sonner";
import { AddColumn } from "@/components/board/add-column";
import { BoardToolbar } from "@/components/board/board-toolbar";
import { Column } from "@/components/board/column";
import { ColumnDeletionDialog } from "@/components/board/column-deletion-dialog";
import { KeyboardShortcuts } from "@/components/board/keyboard-shortcuts";
import { MobileBoard } from "@/components/board/mobile-board";
import { TaskModal } from "@/components/board/task-modal";
import { TaskRecoveryDialog } from "@/components/board/task-recovery-dialog";
import { useThemePreference } from "@/components/theme/theme-preference-provider";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { useBoard } from "@/hooks/use-board";
import type { BoardRefreshOutcome } from "@/hooks/use-board/use-board-sync";
import { useDevice } from "@/hooks/use-device";
import { useHotKeys } from "@/hooks/use-hotkeys";
import { useOnlineStatus } from "@/hooks/use-online-status";
import { usePresence } from "@/hooks/use-presence";
import { useRealtime } from "@/hooks/use-realtime";
import { resolveApplicationAccess } from "@/lib/auth";
import { hasBoardAuthorizationEpochChanged } from "@/lib/board-auth-epoch";
import { columnDeletionSuccessMessage } from "@/lib/column-deletion-flow";
import {
  BoardRecoveryError,
  previewBoardTimeZone,
  updateBoardTimeZone,
} from "@/lib/db/boards";
import { setTaskAssignee, TaskAssigneeError } from "@/lib/db/my-tasks";
import { exportBoard } from "@/lib/export";
import { importBoard } from "@/lib/import";
import {
  abortPendingSessionRequests,
  createClient,
  getSessionAbortSignal,
  getSessionEpoch,
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
  captureTaskDraftForAuthorizationRefresh,
  isTaskDraftAuthorizationRefreshCurrent,
  type PreservedTaskDraft,
  resolveTaskDraftAfterAuthorizationRefresh,
  shouldRetryTaskDraftAuthorizationRefresh,
} from "@/lib/task-draft-preservation";
import {
  captureTaskFocusOrigin,
  selectTaskFocusTarget,
  type TaskFocusOrigin,
} from "@/lib/task-edit-focus";
import type { TaskEditDraft } from "@/lib/task-edit-workflow";
import type {
  AssignableBoardMember,
  BoardRealtimeContext,
  Board as BoardType,
  ColumnWithTasks,
  CurrentBoardMember,
  Task,
  TaskAssigneeCommand,
  TaskAssigneeResult,
  TaskCompletionCommand,
  TaskCompletionResult,
  TaskEditableField,
  TaskFieldVersions,
  TaskOrderResult,
} from "@/lib/types";
import { generateUUID } from "@/lib/utils";

interface BoardProps {
  slug: string;
  initialBoard: BoardType;
  initialColumns: ColumnWithTasks[];
  ownerAuthUserId: string;
  assignableMembers: AssignableBoardMember[] | null;
  currentMembers: CurrentBoardMember[] | null;
  hasOtherCurrentMembers: boolean | null;
  initialTaskId: string | null;
  initialCommentId: string | null;
  myTasksReturnHref: string | null;
}

type BoardWorkspaceProps = Omit<BoardProps, "ownerAuthUserId"> & {
  actorId: string;
  realtimeContext: BoardRealtimeContext;
  isSessionStale: boolean;
  onAccessLost: () => void;
  onRealtimeReconnect: () => void;
};

type SessionStatus = "checking" | "active" | "stale" | "denied";

export function Board({
  slug,
  initialBoard,
  initialColumns,
  ownerAuthUserId,
  assignableMembers,
  currentMembers,
  hasOtherCurrentMembers,
  initialTaskId,
  initialCommentId,
  myTasksReturnHref,
}: BoardProps) {
  const router = useRouter();
  const { resetTheme } = useThemePreference();
  const [sessionStatus, setSessionStatus] = useState<SessionStatus>("checking");
  const [realtimeContext, setRealtimeContext] =
    useState<BoardRealtimeContext | null>(null);
  const realtimeContextRef = useRef<BoardRealtimeContext | null>(null);
  const verifySessionRef = useRef<() => Promise<void>>(() => Promise.resolve());
  const onAccessLost = useCallback(() => {
    abortPendingSessionRequests();
    resetTheme();
    setSessionStatus("denied");
    router.replace("/");
  }, [resetTheme, router]);

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

        if (
          (typeof boardAccess.auth_epoch !== "string" &&
            typeof boardAccess.auth_epoch !== "number") ||
          typeof boardAccess.sync_topic !== "string" ||
          typeof boardAccess.presence_topic !== "string"
        ) {
          preserveSessionData();
          return;
        }
        const nextRealtimeContext: BoardRealtimeContext = {
          auth_epoch: boardAccess.auth_epoch,
          sync_topic: boardAccess.sync_topic,
          presence_topic: boardAccess.presence_topic,
        };

        if (!disposed && generation === verificationGeneration) {
          const currentRealtimeContext = realtimeContextRef.current;
          if (
            currentRealtimeContext &&
            (String(currentRealtimeContext.auth_epoch) !==
              String(nextRealtimeContext.auth_epoch) ||
              currentRealtimeContext.sync_topic !==
                nextRealtimeContext.sync_topic)
          ) {
            abortPendingSessionRequests();
          }
          realtimeContextRef.current = nextRealtimeContext;
          setRealtimeContext((current) => {
            if (
              current &&
              String(current.auth_epoch) ===
                String(nextRealtimeContext.auth_epoch) &&
              current.sync_topic === nextRealtimeContext.sync_topic &&
              current.presence_topic === nextRealtimeContext.presence_topic
            ) {
              return current;
            }
            return nextRealtimeContext;
          });
          setSessionStatus("active");
        }
      } catch {
        preserveSessionData();
      } finally {
        checking = false;
      }
    };
    verifySessionRef.current = verifySession;

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

  const onRealtimeReconnect = useCallback(() => verifySessionRef.current(), []);

  if (
    sessionStatus === "checking" ||
    sessionStatus === "denied" ||
    !realtimeContext
  ) {
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
      realtimeContext={realtimeContext}
      initialBoard={initialBoard}
      initialColumns={initialColumns}
      assignableMembers={assignableMembers}
      currentMembers={currentMembers}
      hasOtherCurrentMembers={hasOtherCurrentMembers}
      initialTaskId={initialTaskId}
      initialCommentId={initialCommentId}
      myTasksReturnHref={myTasksReturnHref}
      isSessionStale={sessionStatus === "stale"}
      onAccessLost={onAccessLost}
      onRealtimeReconnect={onRealtimeReconnect}
    />
  );
}

function BoardWorkspace({
  slug,
  actorId,
  realtimeContext,
  initialBoard,
  initialColumns,
  assignableMembers,
  currentMembers,
  hasOtherCurrentMembers,
  initialTaskId,
  initialCommentId,
  myTasksReturnHref,
  isSessionStale,
  onAccessLost,
  onRealtimeReconnect,
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
  const refreshRef = useRef<(() => Promise<BoardRefreshOutcome>) | undefined>(
    undefined,
  );

  // Ref to hold replaceState - avoids circular dependency between hooks
  const replaceStateRef = useRef<
    ((newBoard: null, newColumns: []) => void) | undefined
  >(undefined);

  const [editingTaskId, setEditingTaskId] = useState<string | null>(null);
  const editingTaskIdRef = useRef<string | null>(editingTaskId);
  editingTaskIdRef.current = editingTaskId;
  const [pendingTaskDraft, setPendingTaskDraft] =
    useState<PreservedTaskDraft | null>(null);
  const [restoredTaskDraft, setRestoredTaskDraft] =
    useState<PreservedTaskDraft | null>(null);
  const isAuthorizationRefreshPending = pendingTaskDraft !== null;
  const dirtyTaskDraftRef = useRef<PreservedTaskDraft | null>(null);
  const pendingTaskDraftRef = useRef<PreservedTaskDraft | null>(null);
  const authorizationRefreshGenerationRef = useRef(0);
  const activeAuthorizationRefreshEpochRef = useRef<string | null>(null);
  const completedAuthorizationRefreshEpochRef = useRef<string | null>(null);
  const workspaceMountedRef = useRef(false);
  const retryDelayCancelRef = useRef<(() => void) | null>(null);
  const actorIdRef = useRef(actorId);
  actorIdRef.current = actorId;
  const previousActorIdRef = useRef(actorId);
  const authEpochRef = useRef(realtimeContext.auth_epoch);
  authEpochRef.current = realtimeContext.auth_epoch;

  const onEditDraftChange = useCallback(
    (
      taskId: string,
      draft: TaskEditDraft,
      dirtyFields: TaskEditableField[],
      baseVersions: TaskFieldVersions,
    ) => {
      if (actorIdRef.current !== actorId) return;
      dirtyTaskDraftRef.current = captureTaskDraftForAuthorizationRefresh({
        actorId,
        taskId,
        authEpoch: authEpochRef.current,
        draft,
        dirtyFields,
        baseVersions,
      });
    },
    [actorId],
  );

  const clearTaskDraft = useCallback((taskId: string) => {
    if (dirtyTaskDraftRef.current?.taskId === taskId) {
      dirtyTaskDraftRef.current = null;
    }
  }, []);

  const onEditDraftRestored = useCallback(() => {
    pendingTaskDraftRef.current = null;
    setPendingTaskDraft(null);
    setRestoredTaskDraft(null);
  }, []);

  useLayoutEffect(() => {
    workspaceMountedRef.current = true;
    return () => {
      workspaceMountedRef.current = false;
      authorizationRefreshGenerationRef.current += 1;
      dirtyTaskDraftRef.current = null;
      pendingTaskDraftRef.current = null;
      activeAuthorizationRefreshEpochRef.current = null;
      completedAuthorizationRefreshEpochRef.current = null;
      retryDelayCancelRef.current?.();
      retryDelayCancelRef.current = null;
    };
  }, []);

  useLayoutEffect(() => {
    if (previousActorIdRef.current !== actorId) {
      previousActorIdRef.current = actorId;
      authorizationRefreshGenerationRef.current += 1;
      dirtyTaskDraftRef.current = null;
      pendingTaskDraftRef.current = null;
      activeAuthorizationRefreshEpochRef.current = null;
      retryDelayCancelRef.current?.();
      retryDelayCancelRef.current = null;
      setPendingTaskDraft(null);
      setRestoredTaskDraft(null);
      setEditingTaskId(null);
    }
  }, [actorId]);

  // Realtime: broadcast sync after every mutation, refetch on incoming sync
  useRealtime({
    authEpoch: realtimeContext.auth_epoch,
    syncTopic: realtimeContext.sync_topic,
    onReconnect: onRealtimeReconnect,
    onSync: () => {
      refreshRef.current?.();
    },
    onBoardDeleted: () => {
      toast.error("Se envió el tablero a recuperación", {
        description: "Otra persona envió este tablero a recuperación.",
      });
      replaceStateRef.current?.(null, []);
      router.push("/");
    },
  });

  const onLocalMutation = useCallback(() => {
    void refreshRef.current?.().catch(() => undefined);
  }, []);

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
    authEpoch: realtimeContext.auth_epoch,
    onMutation: onLocalMutation,
    onAccessLost,
  });

  // Wire the refs after useBoard returns
  refreshRef.current = refreshFromDB;
  replaceStateRef.current = replaceState;

  const refreshAfterAuthorizationEpochChange = useCallback(
    (preservedDraft: PreservedTaskDraft | null) => {
      const generation = ++authorizationRefreshGenerationRef.current;
      const requestActorId = actorIdRef.current;
      const requestAuthEpoch = authEpochRef.current;
      const requestSessionEpoch = getSessionEpoch();
      const requestSignal = getSessionAbortSignal();
      retryDelayCancelRef.current?.();
      retryDelayCancelRef.current = null;
      pendingTaskDraftRef.current = preservedDraft;
      activeAuthorizationRefreshEpochRef.current = String(requestAuthEpoch);
      completedAuthorizationRefreshEpochRef.current = null;
      setPendingTaskDraft(preservedDraft);
      setRestoredTaskDraft(null);
      replaceState(null, []);

      const isCurrentRefresh = () =>
        isTaskDraftAuthorizationRefreshCurrent({
          requestActorId,
          currentActorId: actorIdRef.current,
          requestAuthEpoch,
          currentAuthEpoch: authEpochRef.current,
          requestSessionEpoch,
          currentSessionEpoch: getSessionEpoch(),
          requestSignal,
          isMounted: workspaceMountedRef.current,
          isCurrentGeneration:
            generation === authorizationRefreshGenerationRef.current,
        });

      const finishRefresh = (outcome: BoardRefreshOutcome) => {
        if (!isCurrentRefresh()) return;
        const currentPreservedDraft = pendingTaskDraftRef.current;
        const resolution = resolveTaskDraftAfterAuthorizationRefresh({
          preserved: currentPreservedDraft,
          currentActorId: actorIdRef.current,
          currentAuthEpoch: authEpochRef.current,
          outcome,
        });
        pendingTaskDraftRef.current = null;
        activeAuthorizationRefreshEpochRef.current = null;
        completedAuthorizationRefreshEpochRef.current =
          String(requestAuthEpoch);
        setPendingTaskDraft(null);
        if (resolution.status === "restore") {
          setRestoredTaskDraft(resolution.preserved);
          return;
        }
        setRestoredTaskDraft(null);
        setEditingTaskId(null);
      };

      const refreshUntilResolved = async () => {
        let discardedCount = 0;
        let transientFailureCount = 0;
        while (isCurrentRefresh()) {
          let outcome: BoardRefreshOutcome;
          try {
            outcome = await refreshFromDB();
          } catch {
            outcome = { status: "retryable" };
          }
          if (
            shouldRetryTaskDraftAuthorizationRefresh({
              preserved: pendingTaskDraftRef.current,
              requestActorId,
              currentActorId: actorIdRef.current,
              requestAuthEpoch,
              currentAuthEpoch: authEpochRef.current,
              requestSessionEpoch,
              currentSessionEpoch: getSessionEpoch(),
              requestSignal,
              isMounted: workspaceMountedRef.current,
              isCurrentGeneration:
                generation === authorizationRefreshGenerationRef.current,
              outcome,
            })
          ) {
            const retryDelay =
              outcome.status === "retryable"
                ? Math.min(
                    30_000,
                    1_000 * 2 ** Math.min(transientFailureCount, 5),
                  )
                : Math.min(1_000, 100 * 2 ** Math.min(discardedCount, 3));
            if (outcome.status === "retryable") transientFailureCount += 1;
            else discardedCount += 1;
            await new Promise<void>((resolve) => {
              const timer = window.setTimeout(() => {
                if (retryDelayCancelRef.current === cancelRetryDelay) {
                  retryDelayCancelRef.current = null;
                }
                resolve();
              }, retryDelay);
              const cancelRetryDelay = () => {
                window.clearTimeout(timer);
                if (retryDelayCancelRef.current === cancelRetryDelay) {
                  retryDelayCancelRef.current = null;
                }
                resolve();
              };
              retryDelayCancelRef.current = cancelRetryDelay;
            });
            continue;
          }
          finishRefresh(outcome);
          return;
        }
      };

      void refreshUntilResolved();
    },
    [refreshFromDB, replaceState],
  );

  const previousAuthorizationEpochRef = useRef<string | null>(null);
  useLayoutEffect(() => {
    const currentAuthorizationEpoch = String(realtimeContext.auth_epoch);
    const initialAuthorizationEpochIsStale =
      initialBoard.auth_epoch !== undefined &&
      hasBoardAuthorizationEpochChanged(
        initialBoard.auth_epoch,
        realtimeContext.auth_epoch,
      );
    if (previousAuthorizationEpochRef.current === null) {
      previousAuthorizationEpochRef.current = currentAuthorizationEpoch;
      if (
        initialAuthorizationEpochIsStale &&
        activeAuthorizationRefreshEpochRef.current !==
          currentAuthorizationEpoch &&
        completedAuthorizationRefreshEpochRef.current !==
          currentAuthorizationEpoch
      ) {
        refreshAfterAuthorizationEpochChange(null);
      }
      return;
    }
    if (
      !hasBoardAuthorizationEpochChanged(
        previousAuthorizationEpochRef.current,
        currentAuthorizationEpoch,
      )
    ) {
      if (
        initialAuthorizationEpochIsStale &&
        activeAuthorizationRefreshEpochRef.current !==
          currentAuthorizationEpoch &&
        completedAuthorizationRefreshEpochRef.current !==
          currentAuthorizationEpoch
      ) {
        refreshAfterAuthorizationEpochChange(null);
      }
      return;
    }
    previousAuthorizationEpochRef.current = currentAuthorizationEpoch;
    completedAuthorizationRefreshEpochRef.current = null;
    const latestDraft = dirtyTaskDraftRef.current;
    const preservedDraft =
      latestDraft &&
      latestDraft.actorId === actorIdRef.current &&
      latestDraft.taskId === editingTaskIdRef.current
        ? { ...latestDraft, authEpoch: currentAuthorizationEpoch }
        : null;
    refreshAfterAuthorizationEpochChange(preservedDraft);

    return;
  }, [
    initialBoard.auth_epoch,
    realtimeContext.auth_epoch,
    refreshAfterAuthorizationEpochChange,
  ]);

  useEffect(() => {
    const refreshBoardDay = () => {
      if (document.visibilityState === "visible") {
        void refreshFromDB().catch(() => undefined);
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
  }, [refreshFromDB]);

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
  const { viewerCount, isConnected } = usePresence(
    realtimeContext.presence_topic,
  );

  // Task modal state
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
  const modalRestoredDraft =
    restoredTaskDraft &&
    restoredTaskDraft.actorId === actorId &&
    restoredTaskDraft.taskId === editingTask?.id &&
    String(restoredTaskDraft.authEpoch) ===
      String(realtimeContext.auth_epoch) &&
    board?.auth_epoch !== undefined &&
    String(board.auth_epoch) === String(realtimeContext.auth_epoch)
      ? restoredTaskDraft
      : null;

  useEffect(() => {
    if (editingTaskId && !editingTask && !isAuthorizationRefreshPending) {
      setEditingTaskId(null);
    }
  }, [editingTask, editingTaskId, isAuthorizationRefreshPending]);

  useEffect(() => {
    if (editingTaskId === null) dirtyTaskDraftRef.current = null;
  }, [editingTaskId]);

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
        await refreshFromDB().catch(() => undefined);
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
  const boardDeleteOperationIdRef = useRef<string | null>(null);
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
    const operationId = boardDeleteOperationIdRef.current ?? generateUUID();
    boardDeleteOperationIdRef.current = operationId;
    setIsDeletingBoard(true);
    let completed = false;
    try {
      const result = await removeBoard(operationId);
      if (!result) return;
      const expiresAt = new Intl.DateTimeFormat("es-AR", {
        dateStyle: "medium",
        timeStyle: "short",
      }).format(new Date(result.expires_at ?? ""));
      toast.success("Tablero enviado a recuperación", {
        description: `Podrás restaurarlo hasta el ${expiresAt}. Las invitaciones pendientes se revocaron.`,
      });
      router.push("/");
      completed = true;
    } catch (error) {
      const description =
        error instanceof BoardRecoveryError && error.reason === "access_denied"
          ? "Tu autoridad sobre este tablero cambió. Actualiza el estado antes de volver a intentarlo."
          : error instanceof BoardRecoveryError && error.reason === "conflict"
            ? "El tablero cambió durante la confirmación. Actualiza el estado antes de continuar."
            : "No se pudo confirmar el resultado. Puedes reintentar; se consultará la misma operación sin duplicarla.";
      toast.error("No se pudo enviar el tablero a recuperación", {
        description,
      });
    } finally {
      setIsDeletingBoard(false);
      if (completed) {
        boardDeleteOperationIdRef.current = null;
        setShowDeleteBoard(false);
      }
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
  }

  async function handleDeleteColumn(
    command: Parameters<typeof removeColumn>[0],
  ) {
    return removeColumn(command);
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
        currentMembers={currentMembers}
        canRecoverTasks={
          initialBoard.role === "owner" || initialBoard.role === "collaborator"
        }
        onOpenTaskRecovery={() => setIsTaskRecoveryDialogOpen(true)}
        onPreviewTimeZone={handlePreviewTimeZone}
        onSaveTimeZone={handleSaveTimeZone}
        viewerCount={viewerCount}
        isConnected={isConnected}
        onDeleteBoard={() => {
          boardDeleteOperationIdRef.current = generateUUID();
          setShowDeleteBoard(true);
        }}
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
                  canDelete={columns.length > 1}
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
        restoredDraft={modalRestoredDraft}
        onEditDraftChange={onEditDraftChange}
        onEditDraftRestored={onEditDraftRestored}
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
        open={
          editingTaskId !== null &&
          editingTask !== null &&
          !isAuthorizationRefreshPending
        }
        isOnline={isOnline}
        onClose={() => {
          if (editingTaskId) clearTaskDraft(editingTaskId);
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
          await refreshFromDB();
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
        onClose={() => {
          setShowDeleteBoard(false);
          boardDeleteOperationIdRef.current = null;
        }}
        onConfirm={handleDeleteBoard}
        title="Enviar tablero a recuperación"
        description={`Se ocultará /${slug} y su contenido quedará inaccesible. Podrás restaurarlo durante 7 días. Las invitaciones pendientes se revocarán y no volverán al restaurar.`}
        confirmLabel="Eliminar tablero"
        cancelLabel="Cancelar"
        loading={isDeletingBoard}
      />

      {/* Delete column confirmation */}
      <ColumnDeletionDialog
        open={deletingColumnId !== null}
        slug={slug}
        columnId={deletingColumnId}
        onClose={() => setDeletingColumnId(null)}
        onDelete={handleDeleteColumn}
        onDeleted={(result) => {
          const recoverableUntil = result.expires_at
            ? new Date(result.expires_at).toLocaleString("es-AR", {
                timeZone: board?.time_zone ?? initialBoard.time_zone,
              })
            : null;
          toast.success("Columna eliminada", {
            description: columnDeletionSuccessMessage(
              result.moved_task_count,
              recoverableUntil,
            ),
          });
        }}
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
