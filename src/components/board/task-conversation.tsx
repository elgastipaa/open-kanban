"use client";

import {
  type ChangeEvent,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import {
  createTaskComment,
  deleteTaskComment,
  editTaskComment,
  listTaskComments,
  restoreTaskComment,
  TaskCommentError,
} from "@/lib/db/task-comments";
import { createClient } from "@/lib/supabase/client";
import {
  getOrCreateTaskCommentCreateCommand,
  getTaskCommentThreadViewState,
  mergeTaskComments,
  shouldRetainTaskCommentCommand,
  type TaskCommentCreateOperationStore,
  taskCommentAccessEffect,
  taskCommentCreateFollowUp,
  taskCommentTextSegments,
} from "@/lib/task-comments-state";
import type {
  AssignableBoardMember,
  TaskComment,
  TaskCommentActionCommand,
  TaskCommentCreateCommand,
  TaskCommentEditCommand,
  TaskCommentMentionInput,
} from "@/lib/types";
import { generateUUID } from "@/lib/utils";

interface TaskConversationProps {
  slug: string;
  taskId: string;
  actorId: string;
  role: "owner" | "collaborator";
  initialCommentId: string | null;
  assignableMembers: AssignableBoardMember[] | null;
  operations: TaskCommentCreateOperationStore;
  isOnline: boolean;
  isSessionStale: boolean;
  onAccessLost: () => void;
}

const pageSize = 30;

function commentDate(value: string): string {
  return new Intl.DateTimeFormat("es", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}

function renderCommentText(comment: TaskComment) {
  return taskCommentTextSegments(comment).map((segment, index) => (
    <span
      key={`${segment.isCurrentMember ? "mention" : "text"}-${index}`}
      className={
        segment.isCurrentMember
          ? "rounded bg-accent/15 px-0.5 text-text-primary"
          : undefined
      }
    >
      {segment.text}
    </span>
  ));
}

function mentionsStillMatch(
  content: string,
  mentions: readonly TaskCommentMentionInput[],
  members: readonly AssignableBoardMember[] | null,
): TaskCommentMentionInput[] {
  const characters = Array.from(content);
  return mentions.filter((mention) => {
    const member = members?.find(
      (candidate) => candidate.user_id === mention.user_id,
    );
    if (!member) return false;
    return (
      characters
        .slice(mention.start_char, mention.start_char + mention.length_chars)
        .join("") === `@${member.name}`
    );
  });
}

function appendMemberMention(
  content: string,
  mentions: readonly TaskCommentMentionInput[],
  member: AssignableBoardMember,
): { content: string; mentions: TaskCommentMentionInput[] } {
  const separator = content && !/\s$/u.test(content) ? " " : "";
  const token = `@${member.name}`;
  const prefix = `${content}${separator}`;
  const nextContent = `${prefix}${token} `;
  const nextMention: TaskCommentMentionInput = {
    user_id: member.user_id,
    start_char: Array.from(prefix).length,
    length_chars: Array.from(token).length,
  };
  return {
    content: nextContent,
    mentions: [...mentions, nextMention],
  };
}

function mutationMessage(reason: string): string {
  if (taskCommentAccessEffect(reason).preserveDraft) {
    return "No tienes permiso para realizar esta acción. La conversación y el borrador se conservan.";
  }
  if (reason === "rejected") {
    return "No se guardó el comentario. Revisa el texto y las menciones actuales.";
  }
  if (reason === "conflict") {
    return "La conversación cambió. Actualizamos los comentarios; revisa el texto antes de volver a guardar.";
  }
  if (reason === "expired_unknown") {
    return "El resultado de esta operación ya no se puede confirmar. Se conserva su identificador y no se generará otro; actualiza la conversación para revisar el estado visible.";
  }
  if (reason === "expired") {
    return "Se agotó el plazo para restaurar este comentario.";
  }
  return "No se pudo confirmar el cambio. Puedes reintentar la misma operación.";
}

export function TaskConversation({
  slug,
  taskId,
  actorId,
  role,
  initialCommentId,
  assignableMembers,
  operations,
  isOnline,
  isSessionStale,
  onAccessLost,
}: TaskConversationProps) {
  const [comments, setComments] = useState<TaskComment[]>([]);
  const [pageStatus, setPageStatus] = useState<
    "available" | "unavailable" | null
  >(null);
  const [cursor, setCursor] = useState<{
    created_at: string;
    id: string;
  } | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [isLoadingOlder, setIsLoadingOlder] = useState(false);
  const [loadError, setLoadError] = useState("");
  const [draft, setDraft] = useState("");
  const [mentions, setMentions] = useState<TaskCommentMentionInput[]>([]);
  const [pendingCommand, setPendingCommand] =
    useState<TaskCommentCreateCommand | null>(
      () => operations.get(taskId) ?? null,
    );
  const [isSending, setIsSending] = useState(false);
  const [expiredCreateUnknown, setExpiredCreateUnknown] = useState(() =>
    operations.isCreateExpiredUnknown(taskId),
  );
  const [requiresReview, setRequiresReview] = useState(() =>
    operations.isCreateExpiredUnknown(taskId),
  );
  const [notice, setNotice] = useState("");
  const [editingCommentId, setEditingCommentId] = useState<string | null>(null);
  const [editingDraft, setEditingDraft] = useState("");
  const [editingMentions, setEditingMentions] = useState<
    TaskCommentMentionInput[]
  >([]);
  const [pendingEdit, setPendingEdit] = useState<TaskCommentEditCommand | null>(
    null,
  );
  const [pendingAction, setPendingAction] =
    useState<TaskCommentActionCommand | null>(null);
  const [isMutating, setIsMutating] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState<TaskComment | null>(null);
  const [anchorNotice, setAnchorNotice] = useState("");
  const [scrollTargetId, setScrollTargetId] = useState<string | null>(null);
  const threadRef = useRef<HTMLDivElement>(null);

  const viewState = getTaskCommentThreadViewState({
    isLoading,
    error: loadError,
    pageStatus,
    commentCount: comments.length,
  });
  const members = useMemo(() => assignableMembers ?? [], [assignableMembers]);

  const clearPrivateConversation = useCallback(() => {
    setComments([]);
    setPageStatus("unavailable");
    setCursor(null);
    setHasMore(false);
    setDraft("");
    setMentions([]);
    setPendingCommand(null);
    setPendingEdit(null);
    setPendingAction(null);
    setEditingCommentId(null);
    setEditingDraft("");
    setEditingMentions([]);
    setLoadError("");
    setNotice("");
    operations.clearAll();
    onAccessLost();
  }, [onAccessLost, operations]);

  const applyPage = useCallback(
    (
      page: Extract<
        Awaited<ReturnType<typeof listTaskComments>>,
        { status: "available" }
      >,
    ) => {
      setPageStatus("available");
      setLoadError("");
      setComments((current) => mergeTaskComments(current, page.comments));
      setCursor(page.next_cursor);
      setHasMore(page.has_more);
    },
    [],
  );

  const refreshThread = useCallback(async () => {
    if (!isOnline || isSessionStale) {
      setLoadError("Conéctate para actualizar la conversación.");
      return null;
    }
    try {
      const page = await listTaskComments(createClient(), slug, taskId, {
        limit: pageSize,
        cursor: null,
        anchorCommentId: null,
      });
      if (page.status === "unavailable") {
        clearPrivateConversation();
        return null;
      }
      applyPage(page);
      return page;
    } catch (error) {
      if (
        error instanceof TaskCommentError &&
        taskCommentAccessEffect(error.reason).accessLost
      ) {
        clearPrivateConversation();
        return null;
      }
      setLoadError(
        "No se pudo actualizar la conversación. Inténtalo de nuevo.",
      );
      return null;
    }
  }, [
    applyPage,
    clearPrivateConversation,
    isOnline,
    isSessionStale,
    slug,
    taskId,
  ]);

  useEffect(() => {
    let active = true;
    setComments([]);
    setPageStatus(null);
    setCursor(null);
    setHasMore(false);
    setLoadError("");
    setAnchorNotice("");
    setIsLoading(true);
    const pending = operations.get(taskId);
    setPendingCommand(pending);
    setDraft(pending?.content ?? "");
    if (!isOnline || isSessionStale) {
      setLoadError(
        isSessionStale
          ? "Los datos pueden estar desactualizados. Revisa tu acceso antes de continuar."
          : "Conéctate para cargar la conversación.",
      );
      setIsLoading(false);
      return () => {
        active = false;
      };
    }

    async function loadInitialPage() {
      try {
        const supabase = createClient();
        let page = await listTaskComments(supabase, slug, taskId, {
          limit: pageSize,
          cursor: null,
          anchorCommentId: initialCommentId,
        });
        if (!active) return;
        if (page.status === "unavailable" && initialCommentId) {
          const latestPage = await listTaskComments(supabase, slug, taskId, {
            limit: pageSize,
            cursor: null,
            anchorCommentId: null,
          });
          if (!active) return;
          if (latestPage.status === "available") {
            page = latestPage;
            setAnchorNotice(
              "No se encontró ese comentario. Aquí están los comentarios más recientes.",
            );
          }
        }
        if (page.status === "unavailable") {
          clearPrivateConversation();
          return;
        }
        applyPage(page);
        if (page.anchor_id) {
          setScrollTargetId(page.anchor_id);
          const latestPage = await listTaskComments(supabase, slug, taskId, {
            limit: pageSize,
            cursor: null,
            anchorCommentId: null,
          });
          if (!active) return;
          if (latestPage.status === "unavailable") {
            clearPrivateConversation();
            return;
          }
          applyPage(latestPage);
        } else if (page.comments.length > 0) {
          setScrollTargetId(page.comments.at(-1)?.id ?? null);
        }
      } catch (error) {
        if (!active) return;
        if (
          error instanceof TaskCommentError &&
          taskCommentAccessEffect(error.reason).accessLost
        ) {
          clearPrivateConversation();
        } else {
          setLoadError(
            "No se pudo cargar la conversación. Inténtalo de nuevo.",
          );
        }
      } finally {
        if (active) setIsLoading(false);
      }
    }

    void loadInitialPage();
    return () => {
      active = false;
    };
  }, [
    applyPage,
    clearPrivateConversation,
    initialCommentId,
    isOnline,
    isSessionStale,
    operations,
    slug,
    taskId,
  ]);

  useEffect(() => {
    if (!scrollTargetId) return;
    const element = document.getElementById(`task-comment-${scrollTargetId}`);
    element?.scrollIntoView({ block: "nearest" });
    setScrollTargetId(null);
  }, [scrollTargetId]);

  async function loadOlder() {
    if (!cursor || !hasMore || isLoadingOlder || !isOnline || isSessionStale) {
      return;
    }
    setIsLoadingOlder(true);
    setLoadError("");
    try {
      const page = await listTaskComments(createClient(), slug, taskId, {
        limit: pageSize,
        cursor,
        anchorCommentId: null,
      });
      if (page.status === "unavailable") {
        clearPrivateConversation();
        return;
      }
      applyPage(page);
    } catch (error) {
      if (
        error instanceof TaskCommentError &&
        taskCommentAccessEffect(error.reason).accessLost
      ) {
        clearPrivateConversation();
      } else {
        setLoadError("No se pudieron cargar comentarios anteriores.");
      }
    } finally {
      setIsLoadingOlder(false);
    }
  }

  function selectCreateMention(event: ChangeEvent<HTMLSelectElement>) {
    const member = members.find(
      (candidate) => candidate.user_id === event.target.value,
    );
    event.target.value = "";
    if (!member) return;
    const next = appendMemberMention(draft, mentions, member);
    setDraft(next.content);
    setMentions(next.mentions);
    setNotice("");
  }

  function selectEditMention(event: ChangeEvent<HTMLSelectElement>) {
    const member = members.find(
      (candidate) => candidate.user_id === event.target.value,
    );
    event.target.value = "";
    if (!member) return;
    const next = appendMemberMention(editingDraft, editingMentions, member);
    setEditingDraft(next.content);
    setEditingMentions(next.mentions);
  }

  async function submitComment() {
    if (
      !isOnline ||
      isSessionStale ||
      isSending ||
      requiresReview ||
      expiredCreateUnknown
    ) {
      return;
    }
    const currentMentions = mentionsStillMatch(
      draft,
      mentions,
      assignableMembers,
    );
    if (!draft.trim()) {
      setNotice("Escribe un comentario antes de enviarlo.");
      return;
    }
    const command = getOrCreateTaskCommentCreateCommand(
      pendingCommand ?? operations.get(taskId),
      taskId,
      draft,
      currentMentions,
      generateUUID(),
    );
    operations.set(command);
    setPendingCommand(command);
    setIsSending(true);
    setNotice("");
    try {
      const result = await createTaskComment(createClient(), slug, command);
      const followUp = taskCommentCreateFollowUp(result.status);
      if (result.status === "unavailable") {
        clearPrivateConversation();
        return;
      }
      if (result.status === "expired_unknown") {
        operations.markCreateExpiredUnknown(taskId);
        setExpiredCreateUnknown(true);
      }
      if (followUp.clearDraft) {
        setDraft("");
        setMentions([]);
      }
      if (followUp.clearPendingCommand) {
        operations.clearCreate(taskId);
        setPendingCommand(null);
      }
      setRequiresReview(followUp.requiresReview);
      setNotice(
        result.status === "confirmed"
          ? "Comentario enviado."
          : result.status === "expired_unknown" ||
              result.status === "conflict" ||
              result.status === "forbidden"
            ? mutationMessage(result.status)
            : "No se pudo enviar el comentario.",
      );
      if (followUp.refreshThread) {
        const page = await refreshThread();
        if (result.status === "confirmed" && page) {
          setScrollTargetId(result.comment_id);
        }
      }
    } catch (error) {
      if (
        error instanceof TaskCommentError &&
        taskCommentAccessEffect(error.reason).accessLost
      ) {
        clearPrivateConversation();
        return;
      }
      const reason =
        error instanceof TaskCommentError ? error.reason : "uncertain";
      if (reason === "expired_unknown") {
        operations.markCreateExpiredUnknown(taskId);
        setExpiredCreateUnknown(true);
      }
      if (reason === "rejected" || reason === "conflict") {
        operations.clearCreate(taskId);
        setPendingCommand(null);
      }
      setRequiresReview(reason === "conflict");
      setNotice(mutationMessage(reason));
    } finally {
      setIsSending(false);
    }
  }

  function beginEdit(comment: TaskComment) {
    if (!comment.content || comment.version === null) return;
    const pending = operations.getEdit(taskId, comment.id);
    setEditingCommentId(comment.id);
    setPendingEdit(pending);
    setEditingDraft(pending?.content ?? comment.content);
    setEditingMentions(
      pending?.mentions ??
        comment.mentions
          .filter((mention) => mention.user_id)
          .map(({ user_id, start_char, length_chars }) => ({
            user_id: user_id as string,
            start_char,
            length_chars,
          })),
    );
  }

  function cancelEdit(commentId: string) {
    if (pendingEdit) return;
    setEditingCommentId(null);
    setEditingDraft("");
    setEditingMentions([]);
    operations.clearEdit(taskId, commentId);
  }

  async function saveEdit(comment: TaskComment) {
    if (!comment.version || isMutating || !isOnline || isSessionStale) return;
    if (operations.isEditExpiredUnknown(taskId, comment.id)) {
      await refreshThread();
      return;
    }
    if (!editingDraft.trim()) {
      setNotice("El comentario no puede quedar vacío.");
      return;
    }
    const command = pendingEdit ??
      operations.getEdit(taskId, comment.id) ?? {
        task_id: taskId,
        comment_id: comment.id,
        operation_id: generateUUID(),
        expected_version: comment.version,
        content: editingDraft,
        mentions: mentionsStillMatch(
          editingDraft,
          editingMentions,
          assignableMembers,
        ),
      };
    operations.setEdit(command);
    setPendingEdit(command);
    setIsMutating(true);
    setNotice("");
    try {
      const result = await editTaskComment(createClient(), slug, command);
      if (result.status === "unavailable") {
        clearPrivateConversation();
        return;
      }
      if (result.status === "confirmed") {
        operations.clearEdit(taskId, comment.id);
        setPendingEdit(null);
        setEditingCommentId(null);
        setEditingDraft("");
        setEditingMentions([]);
        setNotice("Comentario actualizado.");
      } else if (result.status === "forbidden") {
        operations.clearEdit(taskId, comment.id);
        setPendingEdit(null);
        setNotice(mutationMessage(result.status));
      } else if (shouldRetainTaskCommentCommand(result.status)) {
        operations.markEditExpiredUnknown(taskId, comment.id);
        setPendingEdit(null);
        setEditingCommentId(null);
        setEditingDraft("");
        setEditingMentions([]);
        setNotice(mutationMessage(result.status));
      } else {
        operations.clearEdit(taskId, comment.id);
        setPendingEdit(null);
        setNotice(
          "El comentario cambió. Revisa la versión actual antes de volver a editarlo.",
        );
      }
      await refreshThread();
    } catch (error) {
      if (
        error instanceof TaskCommentError &&
        taskCommentAccessEffect(error.reason).accessLost
      ) {
        clearPrivateConversation();
        return;
      }
      const reason =
        error instanceof TaskCommentError ? error.reason : "uncertain";
      if (reason === "rejected" || reason === "conflict") {
        operations.clearEdit(taskId, comment.id);
        setPendingEdit(null);
      }
      setNotice(mutationMessage(reason));
      if (reason === "conflict") await refreshThread();
    } finally {
      setIsMutating(false);
    }
  }

  async function confirmDelete(comment: TaskComment) {
    if (isMutating || !isOnline || isSessionStale) return;
    if (operations.isActionExpiredUnknown("delete", taskId, comment.id)) {
      await refreshThread();
      return;
    }
    const command = operations.getAction("delete", taskId, comment.id) ?? {
      action: "delete" as const,
      task_id: taskId,
      comment_id: comment.id,
      operation_id: generateUUID(),
    };
    operations.setAction(command);
    setPendingAction(command);
    setIsMutating(true);
    try {
      const result = await deleteTaskComment(
        createClient(),
        slug,
        command.operation_id,
        comment.id,
      );
      if (result.status === "unavailable") {
        clearPrivateConversation();
        return;
      }
      if (result.status === "confirmed") {
        operations.clearAction("delete", taskId, comment.id);
        setPendingAction(null);
        setDeleteTarget(null);
        setNotice("Comentario eliminado.");
      } else if (shouldRetainTaskCommentCommand(result.status)) {
        operations.markActionExpiredUnknown("delete", taskId, comment.id);
        setPendingAction(null);
        setDeleteTarget(null);
        setNotice(mutationMessage(result.status));
      } else {
        operations.clearAction("delete", taskId, comment.id);
        setPendingAction(null);
        setDeleteTarget(null);
        setNotice(mutationMessage(result.status));
      }
      await refreshThread();
    } catch (error) {
      if (
        error instanceof TaskCommentError &&
        taskCommentAccessEffect(error.reason).accessLost
      ) {
        clearPrivateConversation();
        return;
      }
      const reason =
        error instanceof TaskCommentError ? error.reason : "uncertain";
      if (reason === "rejected" || reason === "conflict") {
        operations.clearAction("delete", taskId, comment.id);
        setPendingAction(null);
        setDeleteTarget(null);
      }
      setNotice(mutationMessage(reason));
    } finally {
      setIsMutating(false);
    }
  }

  async function restoreComment(comment: TaskComment) {
    if (isMutating || !isOnline || isSessionStale) return;
    if (operations.isActionExpiredUnknown("restore", taskId, comment.id)) {
      await refreshThread();
      return;
    }
    const command = operations.getAction("restore", taskId, comment.id) ?? {
      action: "restore" as const,
      task_id: taskId,
      comment_id: comment.id,
      operation_id: generateUUID(),
    };
    operations.setAction(command);
    setPendingAction(command);
    setIsMutating(true);
    try {
      const result = await restoreTaskComment(
        createClient(),
        slug,
        command.operation_id,
        comment.id,
      );
      if (result.status === "unavailable") {
        clearPrivateConversation();
        return;
      }
      if (result.status === "confirmed") {
        operations.clearAction("restore", taskId, comment.id);
        setPendingAction(null);
        setNotice("Comentario restaurado.");
      } else if (shouldRetainTaskCommentCommand(result.status)) {
        operations.markActionExpiredUnknown("restore", taskId, comment.id);
        setPendingAction(null);
        setNotice(mutationMessage(result.status));
      } else {
        operations.clearAction("restore", taskId, comment.id);
        setPendingAction(null);
        setNotice(mutationMessage(result.status));
      }
      await refreshThread();
    } catch (error) {
      if (
        error instanceof TaskCommentError &&
        taskCommentAccessEffect(error.reason).accessLost
      ) {
        clearPrivateConversation();
        return;
      }
      const reason =
        error instanceof TaskCommentError ? error.reason : "uncertain";
      if (reason === "rejected" || reason === "conflict") {
        operations.clearAction("restore", taskId, comment.id);
        setPendingAction(null);
      }
      setNotice(mutationMessage(reason));
    } finally {
      setIsMutating(false);
    }
  }

  function renderMentionPicker(
    label: string,
    onChange: (event: ChangeEvent<HTMLSelectElement>) => void,
  ) {
    return (
      <select
        aria-label={label}
        defaultValue=""
        onChange={onChange}
        disabled={!isOnline || isSessionStale || members.length === 0}
        className="h-9 min-w-0 rounded-md border border-border bg-surface-base px-2 text-text-secondary text-xs outline-none focus:border-accent disabled:opacity-50"
      >
        <option value="">Mencionar a…</option>
        {members.map((member) => (
          <option key={member.user_id} value={member.user_id}>
            {member.name}
          </option>
        ))}
      </select>
    );
  }

  return (
    <section
      className="space-y-3 border-border border-t pt-4"
      aria-labelledby="task-conversation-heading"
    >
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3
          id="task-conversation-heading"
          className="font-semibold text-sm text-text-primary"
        >
          Conversación
        </h3>
        {viewState === "ready" && (
          <span className="text-text-muted text-xs">
            {comments.length} comentario
            {comments.length === 1 ? " cargado" : "s cargados"}
          </span>
        )}
      </div>

      {isSessionStale && (
        <p className="rounded-md border border-border bg-surface-raised p-3 text-text-secondary text-xs">
          Los datos podrían estar desactualizados. No se enviarán cambios hasta
          confirmar la sesión.
        </p>
      )}

      {anchorNotice && (
        <output className="text-text-secondary text-xs" aria-live="polite">
          {anchorNotice}
        </output>
      )}

      <div
        ref={threadRef}
        className="max-h-80 space-y-3 overflow-y-auto rounded-md border border-border bg-surface-base p-3"
        aria-live="polite"
        aria-busy={isLoading || isLoadingOlder}
      >
        {viewState === "loading" && (
          <p className="text-sm text-text-secondary">Cargando conversación…</p>
        )}
        {viewState === "error" && (
          <div className="space-y-2 text-sm">
            <p className="text-priority-medium">
              {loadError || "No se pudo cargar la conversación."}
            </p>
            <Button
              type="button"
              size="sm"
              variant="ghost"
              disabled={!isOnline || isSessionStale}
              onClick={() => void refreshThread()}
            >
              Reintentar carga
            </Button>
          </div>
        )}
        {viewState === "access-lost" && (
          <p className="text-sm text-text-secondary">
            Ya no tienes acceso a esta conversación.
          </p>
        )}
        {viewState === "empty" && (
          <p className="text-sm text-text-secondary">
            Todavía no hay comentarios. Puedes iniciar la conversación.
          </p>
        )}

        {viewState === "ready" && hasMore && (
          <div className="text-center">
            <Button
              type="button"
              size="sm"
              variant="ghost"
              disabled={isLoadingOlder || !isOnline || isSessionStale}
              onClick={() => void loadOlder()}
            >
              {isLoadingOlder ? "Cargando…" : "Cargar comentarios anteriores"}
            </Button>
          </div>
        )}

        {viewState === "ready" &&
          comments.map((comment) => {
            const isAuthor = comment.author_id === actorId;
            const canDelete = isAuthor || role === "owner";
            const isEditing = editingCommentId === comment.id;
            const hasPendingDelete =
              operations.getAction("delete", taskId, comment.id) !== null;
            const hasPendingRestore =
              operations.getAction("restore", taskId, comment.id) !== null;
            const deleteExpiredUnknown = operations.isActionExpiredUnknown(
              "delete",
              taskId,
              comment.id,
            );
            const restoreExpiredUnknown = operations.isActionExpiredUnknown(
              "restore",
              taskId,
              comment.id,
            );
            const editExpiredUnknown = operations.isEditExpiredUnknown(
              taskId,
              comment.id,
            );
            return (
              <article
                key={comment.id}
                id={`task-comment-${comment.id}`}
                tabIndex={comment.id === initialCommentId ? -1 : undefined}
                className={`space-y-2 rounded-md border p-3 ${
                  comment.id === initialCommentId
                    ? "border-accent bg-accent/5"
                    : "border-border/70 bg-surface-overlay/40"
                }`}
              >
                <header className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
                  <div className="flex min-w-0 flex-wrap items-baseline gap-x-2">
                    <span className="break-words font-medium text-sm text-text-primary">
                      {comment.author_name}
                    </span>
                    <time
                      dateTime={comment.created_at}
                      className="text-text-muted text-xs"
                    >
                      {commentDate(comment.created_at)}
                    </time>
                    {comment.edited_at && !comment.deleted && (
                      <span className="text-text-muted text-xs">· editado</span>
                    )}
                  </div>
                </header>

                {comment.deleted ? (
                  <p className="text-sm text-text-muted italic">
                    Este comentario se eliminó.
                  </p>
                ) : isEditing ? (
                  <div className="space-y-2">
                    <textarea
                      aria-label="Editar comentario"
                      value={editingDraft}
                      disabled={
                        isMutating ||
                        !isOnline ||
                        isSessionStale ||
                        pendingEdit !== null
                      }
                      onChange={(event) => {
                        const content = event.target.value;
                        setEditingDraft(content);
                        setEditingMentions((current) =>
                          mentionsStillMatch(
                            content,
                            current,
                            assignableMembers,
                          ),
                        );
                      }}
                      rows={3}
                      className="w-full resize-y rounded-md border border-border bg-surface-base px-3 py-2 text-sm text-text-primary outline-none focus:border-accent disabled:opacity-50"
                    />
                    <div className="flex flex-wrap items-center gap-2">
                      {renderMentionPicker(
                        "Mencionar miembro al editar",
                        selectEditMention,
                      )}
                      <Button
                        type="button"
                        size="sm"
                        variant="primary"
                        disabled={
                          isMutating ||
                          !isOnline ||
                          isSessionStale ||
                          editExpiredUnknown
                        }
                        onClick={() =>
                          editExpiredUnknown
                            ? void refreshThread()
                            : void saveEdit(comment)
                        }
                      >
                        {isMutating
                          ? "Guardando…"
                          : editExpiredUnknown
                            ? "Actualizar conversación"
                            : pendingEdit
                              ? "Reintentar edición"
                              : "Guardar comentario"}
                      </Button>
                      <Button
                        type="button"
                        size="sm"
                        variant="ghost"
                        disabled={isMutating || pendingEdit !== null}
                        onClick={() => cancelEdit(comment.id)}
                      >
                        Cancelar
                      </Button>
                    </div>
                  </div>
                ) : (
                  <p className="whitespace-pre-wrap break-words text-sm text-text-secondary">
                    {renderCommentText(comment)}
                  </p>
                )}

                <div className="flex flex-wrap gap-1">
                  {!comment.deleted && isAuthor && !isEditing && (
                    <Button
                      type="button"
                      size="sm"
                      variant="ghost"
                      disabled={!isOnline || isSessionStale || isMutating}
                      onClick={() =>
                        editExpiredUnknown
                          ? void refreshThread()
                          : beginEdit(comment)
                      }
                    >
                      {editExpiredUnknown
                        ? "Actualizar conversación"
                        : "Editar"}
                    </Button>
                  )}
                  {!comment.deleted && canDelete && (
                    <Button
                      type="button"
                      size="sm"
                      variant="danger"
                      disabled={!isOnline || isSessionStale || isMutating}
                      onClick={() =>
                        deleteExpiredUnknown
                          ? void refreshThread()
                          : setDeleteTarget(comment)
                      }
                    >
                      {deleteExpiredUnknown
                        ? "Actualizar conversación"
                        : hasPendingDelete
                          ? role === "owner" && !isAuthor
                            ? "Revisar moderación"
                            : "Revisar eliminación"
                          : role === "owner" && !isAuthor
                            ? "Moderar"
                            : "Eliminar"}
                    </Button>
                  )}
                  {comment.deleted && comment.can_restore && (
                    <Button
                      type="button"
                      size="sm"
                      variant="ghost"
                      disabled={!isOnline || isSessionStale || isMutating}
                      onClick={() =>
                        restoreExpiredUnknown
                          ? void refreshThread()
                          : void restoreComment(comment)
                      }
                    >
                      {isMutating && pendingAction?.action === "restore"
                        ? "Restaurando…"
                        : restoreExpiredUnknown
                          ? "Actualizar conversación"
                          : hasPendingRestore
                            ? "Revisar restauración"
                            : "Restaurar comentario"}
                    </Button>
                  )}
                </div>
              </article>
            );
          })}
      </div>

      {loadError && viewState !== "error" && viewState !== "access-lost" && (
        <output className="text-priority-medium text-xs" aria-live="polite">
          {loadError}
        </output>
      )}

      {notice && (
        <output
          className="block text-text-secondary text-xs"
          aria-live="polite"
        >
          {notice}
        </output>
      )}

      {requiresReview && (
        <div className="space-y-2 rounded-md border border-border bg-surface-raised p-3">
          <p className="text-text-secondary text-xs">
            {expiredCreateUnknown
              ? "El resultado del envío sigue sin confirmarse. Se conserva el mismo identificador y no se iniciará otro envío. Actualiza la conversación para revisar si el comentario aparece."
              : "Revisa la conversación antes de iniciar un nuevo envío. No se volverá a enviar el resultado incierto automáticamente."}
          </p>
          <Button
            type="button"
            size="sm"
            variant="ghost"
            disabled={isLoading || isMutating || isSending}
            onClick={() => {
              if (expiredCreateUnknown) {
                void refreshThread();
              } else {
                setRequiresReview(false);
              }
            }}
          >
            {expiredCreateUnknown
              ? "Actualizar conversación"
              : "Ya revisé la conversación"}
          </Button>
        </div>
      )}

      {assignableMembers === null && (
        <output className="text-text-muted text-xs" aria-live="polite">
          No se pudieron cargar los miembros. Puedes escribir texto; las
          menciones necesitan una lista actualizada.
        </output>
      )}

      {viewState !== "access-lost" && (
        <div className="space-y-2">
          <label
            htmlFor={`task-comment-composer-${taskId}`}
            className="block font-medium text-text-secondary text-xs"
          >
            Escribir un comentario
          </label>
          <textarea
            id={`task-comment-composer-${taskId}`}
            aria-label="Escribir un comentario"
            value={draft}
            disabled={
              !isOnline ||
              isSessionStale ||
              isSending ||
              pendingCommand !== null ||
              requiresReview
            }
            onChange={(event) => {
              const content = event.target.value;
              setDraft(content);
              setMentions((current) =>
                mentionsStillMatch(content, current, assignableMembers),
              );
              setNotice("");
            }}
            rows={3}
            placeholder="Escribe un comentario…"
            className="w-full resize-y rounded-md border border-border bg-surface-base px-3 py-2 text-sm text-text-primary outline-none transition-colors placeholder:text-text-muted/60 focus:border-accent disabled:opacity-50"
          />
          <div className="flex flex-wrap items-center justify-between gap-2">
            {renderMentionPicker("Mencionar miembro", selectCreateMention)}
            <Button
              type="button"
              variant="primary"
              disabled={
                !isOnline ||
                isSessionStale ||
                isSending ||
                requiresReview ||
                expiredCreateUnknown ||
                (pendingCommand === null && !draft.trim())
              }
              onClick={() => void submitComment()}
            >
              {isSending
                ? "Enviando…"
                : expiredCreateUnknown
                  ? "Resultado sin confirmar"
                  : pendingCommand
                    ? "Reintentar envío pendiente"
                    : requiresReview
                      ? "Revisa antes de enviar"
                      : "Enviar comentario"}
            </Button>
          </div>
          {pendingCommand && (
            <p className="text-text-secondary text-xs">
              Se conservará el mismo envío al reintentar. El texto no se guarda
              en el navegador.
            </p>
          )}
          {!isOnline && (
            <output className="text-text-muted text-xs" aria-live="polite">
              Sin conexión. El comentario no se enviará ni se pondrá en cola.
            </output>
          )}
        </div>
      )}

      <ConfirmDialog
        open={deleteTarget !== null}
        onClose={() => {
          if (!isMutating) setDeleteTarget(null);
        }}
        onConfirm={() => {
          if (deleteTarget) void confirmDelete(deleteTarget);
        }}
        title={
          deleteTarget?.author_id === actorId
            ? "¿Eliminar tu comentario?"
            : "¿Moderar este comentario?"
        }
        description={
          deleteTarget?.author_id === actorId
            ? "El comentario quedará oculto y podrás restaurarlo durante siete días si mantienes acceso."
            : "El comentario quedará oculto como moderación. Solo el propietario actual podrá restaurarlo durante siete días."
        }
        confirmLabel="Eliminar comentario"
        cancelLabel="Cancelar"
        loading={isMutating && pendingAction?.action === "delete"}
      />
    </section>
  );
}
