"use client";

import { IconCheck } from "@tabler/icons-react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { useOnlineStatus } from "@/hooks/use-online-status";
import { setTaskCompletion, TaskCompletionError } from "@/lib/db/tasks";
import { getMyTaskCompletionControl } from "@/lib/my-task-completion-control";
import { myTaskBoardHref, myTasksHref } from "@/lib/my-tasks-navigation";
import { createClient } from "@/lib/supabase/client";
import { formatTaskDueDate, taskDueState } from "@/lib/task-date";
import type { MyTaskEntry, MyTasksOrder } from "@/lib/types";
import { generateUUID } from "@/lib/utils";

interface MyTasksListProps {
  entries: MyTaskEntry[];
  order: MyTasksOrder;
  loadError: boolean;
}

function dueLabel(entry: MyTaskEntry): string {
  const dateLabel = formatTaskDueDate(entry.task.due_on);
  if (!dateLabel) return "Sin fecha";
  const state = taskDueState(
    entry.task.due_on,
    entry.board.today,
    entry.task.is_completed,
  );
  if (state === "overdue") return `Vencida · ${dateLabel}`;
  if (state === "today") return `Hoy · ${dateLabel}`;
  return dateLabel;
}

function priorityLabel(priority: MyTaskEntry["task"]["priority"]): string {
  switch (priority) {
    case "low":
      return "Baja";
    case "medium":
      return "Media";
    case "high":
      return "Alta";
    case "urgent":
      return "Urgente";
  }
}

export function MyTasksList({ entries, order, loadError }: MyTasksListProps) {
  const router = useRouter();
  const { isOnline } = useOnlineStatus();
  const [pendingTaskId, setPendingTaskId] = useState<string | null>(null);
  const [actionNotice, setActionNotice] = useState("");

  async function toggleCompletion(entry: MyTaskEntry) {
    if (entry.task.is_completed || pendingTaskId || !isOnline) return;
    setPendingTaskId(entry.task.id);
    setActionNotice("");
    try {
      const result = await setTaskCompletion(createClient(), entry.board.slug, {
        id: entry.task.id,
        operation_id: generateUUID(),
        is_completed: true,
        expected_version: entry.task.completion_version,
      });
      if (result.status === "confirmed") {
        router.refresh();
      } else if (result.status === "conflict") {
        setActionNotice(
          "El estado cambió en otro momento. Actualizamos Mis tareas; revisa antes de volver a intentarlo.",
        );
        router.refresh();
      } else {
        setActionNotice(
          "No se pudo confirmar el cambio. Actualiza Mis tareas antes de volver a intentarlo.",
        );
        router.refresh();
      }
    } catch (error) {
      setActionNotice(
        error instanceof TaskCompletionError && error.reason === "access_denied"
          ? "Ya no tienes acceso a ese tablero. Actualizamos Mis tareas."
          : "No se pudo confirmar el cambio. Actualiza Mis tareas antes de volver a intentarlo.",
      );
      router.refresh();
    } finally {
      setPendingTaskId(null);
    }
  }

  const activeEntries = entries.filter((entry) => !entry.task.is_completed);
  const completedEntries = entries.filter((entry) => entry.task.is_completed);

  function renderTask(entry: MyTaskEntry) {
    const isPending = pendingTaskId === entry.task.id;
    const titleHref = myTaskBoardHref(entry.board.slug, entry.task.id, order);
    const completionControl = getMyTaskCompletionControl(
      entry.task.is_completed,
      entry.task.title,
    );
    return (
      <li
        key={`${entry.board.id}:${entry.task.id}`}
        className="flex items-start gap-3 rounded-2xl border border-white/10 bg-neutral-950 p-4 sm:items-center"
      >
        {completionControl.kind === "action" ? (
          <button
            type="button"
            onClick={() => void toggleCompletion(entry)}
            aria-label={completionControl.accessibleLabel}
            title={completionControl.label}
            disabled={!isOnline || Boolean(pendingTaskId)}
            className="mt-0.5 inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-full border border-white/30 text-transparent transition hover:border-emerald-400 disabled:cursor-not-allowed disabled:opacity-50"
          >
            <IconCheck size={14} aria-hidden="true" />
          </button>
        ) : (
          <span
            role="img"
            aria-label={completionControl.accessibleLabel}
            title={completionControl.label}
            className="mt-0.5 inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-full border border-emerald-400 bg-emerald-500/20 text-emerald-300"
          >
            <IconCheck size={14} aria-hidden="true" />
          </span>
        )}
        <div className="min-w-0 flex-1">
          <Link
            href={titleHref}
            className={`block truncate font-medium text-sm hover:text-emerald-200 ${entry.task.is_completed ? "text-neutral-400 line-through" : "text-white"}`}
          >
            {entry.task.title}
          </Link>
          <p className="mt-1 truncate text-neutral-400 text-xs">
            {entry.board.name} · {entry.column.title}
          </p>
          <p className="mt-1 text-neutral-500 text-xs">
            {entry.board.time_zone} · {dueLabel(entry)} · Prioridad:{" "}
            {priorityLabel(entry.task.priority)}
          </p>
        </div>
        {isPending ? (
          <output
            className="shrink-0 text-neutral-400 text-xs"
            aria-live="polite"
          >
            Guardando…
          </output>
        ) : null}
      </li>
    );
  }

  return (
    <main className="mx-auto min-h-dvh max-w-5xl bg-black px-5 py-8 text-white sm:px-8">
      <header className="flex items-center justify-between gap-4 border-white/10 border-b pb-6">
        <div>
          <Link href="/" className="text-neutral-400 text-sm hover:text-white">
            Tableros
          </Link>
          <h1 className="mt-2 font-bold font-display text-3xl tracking-tight">
            Mis tareas
          </h1>
        </div>
        <div className="flex items-center gap-2">
          <Link
            href={myTasksHref("due")}
            aria-current={order === "due" ? "page" : undefined}
            className={`rounded-lg border px-3 py-2 text-sm ${order === "due" ? "border-emerald-400/50 bg-emerald-400/10 text-emerald-200" : "border-white/15 text-neutral-300 hover:bg-white/5"}`}
          >
            Por vencimiento
          </Link>
          <Link
            href={myTasksHref("created")}
            aria-current={order === "created" ? "page" : undefined}
            className={`rounded-lg border px-3 py-2 text-sm ${order === "created" ? "border-emerald-400/50 bg-emerald-400/10 text-emerald-200" : "border-white/15 text-neutral-300 hover:bg-white/5"}`}
          >
            Por creación
          </Link>
        </div>
      </header>

      {!isOnline ? (
        <output
          className="mt-5 block rounded-xl border border-amber-300/20 bg-amber-300/5 p-3 text-amber-100 text-sm"
          aria-live="polite"
        >
          Estás sin conexión. Puedes revisar estas tareas; las acciones
          necesitan conexión.
        </output>
      ) : null}
      {actionNotice ? (
        <output
          className="mt-5 block rounded-xl border border-amber-300/20 bg-amber-300/5 p-3 text-amber-100 text-sm"
          aria-live="polite"
        >
          {actionNotice}
        </output>
      ) : null}

      {loadError ? (
        <p
          className="mt-8 rounded-xl border border-red-400/20 bg-red-400/5 p-4 text-red-200 text-sm"
          role="alert"
        >
          No se pudieron cargar tus tareas. Actualiza la página para volver a
          intentarlo.
        </p>
      ) : entries.length === 0 ? (
        <p className="mt-8 rounded-2xl border border-white/15 border-dashed p-10 text-center text-neutral-400 text-sm">
          No tenés tareas asignadas.
        </p>
      ) : (
        <div className="mt-8 space-y-8">
          {activeEntries.length ? (
            <section aria-labelledby="my-active-tasks-heading">
              <h2
                id="my-active-tasks-heading"
                className="mb-3 font-semibold text-neutral-200 text-sm"
              >
                Pendientes
              </h2>
              <ul className="space-y-2">{activeEntries.map(renderTask)}</ul>
            </section>
          ) : null}
          {completedEntries.length ? (
            <section aria-labelledby="my-completed-tasks-heading">
              <h2
                id="my-completed-tasks-heading"
                className="mb-3 font-semibold text-neutral-200 text-sm"
              >
                Completadas recientemente
              </h2>
              <ul className="space-y-2">{completedEntries.map(renderTask)}</ul>
            </section>
          ) : null}
        </div>
      )}
      {pendingTaskId ? (
        <output className="sr-only" aria-live="polite">
          Actualizando tarea…
        </output>
      ) : null}
    </main>
  );
}
