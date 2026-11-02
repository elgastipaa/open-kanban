"use client";

import { IconArrowUpRight, IconRefresh } from "@tabler/icons-react";
import { useRouter } from "next/navigation";
import { useCallback, useMemo, useState } from "react";
import {
  getMyTaskNotificationTarget,
  listMyTaskNotifications,
  markMyTaskNotificationRead,
  TaskNotificationError,
  type TaskNotificationFilter,
} from "@/lib/db/task-notifications";
import { createClient, getSessionEpoch } from "@/lib/supabase/client";
import {
  applyTaskNotificationRead,
  hideTaskNotificationTargets,
  openTaskNotificationTarget,
  type TaskNotificationItem,
  type TaskNotificationPage,
  taskNotificationReasonLabel,
} from "@/lib/task-notification-state";

interface TaskNotificationsInboxProps {
  initialPage: TaskNotificationPage | null;
  initialLoadFailed: boolean;
}

function formatTimestamp(value: string): string {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return "Fecha desconocida";
  return new Intl.DateTimeFormat("es-AR", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

function availablePage(
  page: TaskNotificationPage | null,
): Extract<TaskNotificationPage, { status: "available" }> | null {
  return page?.status === "available" ? page : null;
}

export function TaskNotificationsInbox({
  initialPage,
  initialLoadFailed,
}: TaskNotificationsInboxProps) {
  const router = useRouter();
  const supabase = useMemo(() => createClient(), []);
  const initialAvailablePage = availablePage(initialPage);
  const [items, setItems] = useState<TaskNotificationItem[]>(
    initialAvailablePage?.items ?? [],
  );
  const [unreadCount, setUnreadCount] = useState(
    initialAvailablePage?.unread_count ?? 0,
  );
  const [cursor, setCursor] = useState(
    initialAvailablePage?.next_cursor ?? null,
  );
  const [hasMore, setHasMore] = useState(
    initialAvailablePage?.has_more ?? false,
  );
  const [filter, setFilter] = useState<TaskNotificationFilter>("all");
  const [busyId, setBusyId] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState(
    initialLoadFailed ? "No se pudieron cargar las novedades." : "",
  );
  const [accessUnavailable, setAccessUnavailable] = useState(
    initialPage?.status === "unavailable",
  );
  const [notice, setNotice] = useState("");

  const refresh = useCallback(
    async (
      nextFilter: TaskNotificationFilter = filter,
      append = false,
    ): Promise<void> => {
      setIsLoading(true);
      setError("");
      setNotice("");
      const requestEpoch = getSessionEpoch();
      try {
        const page = await listMyTaskNotifications(
          supabase,
          nextFilter,
          30,
          append ? cursor : null,
        );
        if (requestEpoch !== getSessionEpoch()) return;
        if (page.status === "unavailable") {
          setItems([]);
          setUnreadCount(0);
          setCursor(null);
          setHasMore(false);
          setAccessUnavailable(true);
          setNotice("Las novedades no están disponibles para esta cuenta.");
          return;
        }
        setAccessUnavailable(false);
        setItems((previous) => {
          const nextItems = append ? [...previous, ...page.items] : page.items;
          return nextItems.filter(
            (item, index, rows) =>
              rows.findIndex((candidate) => candidate.id === item.id) === index,
          );
        });
        setUnreadCount(page.unread_count);
        setCursor(page.next_cursor);
        setHasMore(page.has_more);
        setFilter(nextFilter);
      } catch (caught) {
        if (requestEpoch !== getSessionEpoch()) return;
        setError(
          caught instanceof TaskNotificationError
            ? caught.message
            : "No se pudieron cargar las novedades. Inténtalo de nuevo.",
        );
      } finally {
        if (requestEpoch === getSessionEpoch()) setIsLoading(false);
      }
    },
    [cursor, filter, supabase],
  );

  const markRead = useCallback(
    async (
      item: TaskNotificationItem,
    ): Promise<"confirmed" | "unavailable"> => {
      const requestEpoch = getSessionEpoch();
      setBusyId(item.id);
      setError("");
      try {
        const result = await markMyTaskNotificationRead(supabase, item.id);
        if (requestEpoch !== getSessionEpoch()) return "unavailable";
        if (result === "confirmed") {
          if (item.read_at === null) {
            const readAt = new Date().toISOString();
            setUnreadCount((count) => Math.max(0, count - 1));
            setItems((previous) =>
              applyTaskNotificationRead(previous, item.id, readAt, filter),
            );
          }
          return result;
        }
        setNotice("Esta novedad ya no está disponible para esta cuenta.");
        void refresh(filter);
        return result;
      } catch {
        if (requestEpoch === getSessionEpoch()) {
          setError(
            "No se pudo marcar la novedad como leída. Inténtalo de nuevo.",
          );
        }
        return "unavailable";
      } finally {
        if (requestEpoch === getSessionEpoch()) setBusyId(null);
      }
    },
    [filter, refresh, supabase],
  );

  const open = useCallback(
    async (item: TaskNotificationItem) => {
      const requestEpoch = getSessionEpoch();
      setBusyId(item.id);
      setError("");
      setNotice("");
      const result = await openTaskNotificationTarget(
        item.id,
        (id) => getMyTaskNotificationTarget(supabase, id),
        (id) => markMyTaskNotificationRead(supabase, id),
        (href) => {
          if (requestEpoch === getSessionEpoch()) router.push(href);
        },
      );
      if (requestEpoch !== getSessionEpoch()) return;
      if (result === "unavailable") {
        // A destination check may reveal that the current page is stale after
        // membership or task access changed. Hide every cached title before
        // rebuilding the page from the authorized list RPC.
        setItems(hideTaskNotificationTargets);
        void refresh(filter);
        setNotice(
          "Esta tarea ya no está disponible. Puedes marcar la novedad como leída.",
        );
      } else if (result === "error") {
        setError("No se pudo validar el destino. Inténtalo de nuevo.");
      }
      setBusyId(null);
    },
    [filter, refresh, router, supabase],
  );

  const changeFilter = (nextFilter: TaskNotificationFilter) => {
    if (nextFilter === filter || isLoading) return;
    void refresh(nextFilter);
  };

  return (
    <section aria-labelledby="task-notifications-title" className="mt-8">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div>
          <h2 id="task-notifications-title" className="font-semibold text-lg">
            Novedades recientes
          </h2>
          <p className="mt-1 text-sm text-text-secondary">
            {unreadCount} sin leer · Se conservan durante 90 días.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <button
            type="button"
            aria-pressed={filter === "all"}
            onClick={() => changeFilter("all")}
            disabled={isLoading}
            className="min-h-10 rounded-lg border border-border px-3 text-sm text-text-secondary transition hover:bg-surface-hover hover:text-text-primary focus-visible:outline-2 focus-visible:outline-focus-ring focus-visible:outline-offset-2 disabled:opacity-60"
          >
            Todas
          </button>
          <button
            type="button"
            aria-pressed={filter === "unread"}
            onClick={() => changeFilter("unread")}
            disabled={isLoading}
            className="min-h-10 rounded-lg border border-border px-3 text-sm text-text-secondary transition hover:bg-surface-hover hover:text-text-primary focus-visible:outline-2 focus-visible:outline-focus-ring focus-visible:outline-offset-2 disabled:opacity-60"
          >
            Sin leer
          </button>
          <button
            type="button"
            onClick={() => void refresh(filter)}
            disabled={isLoading}
            className="inline-flex min-h-10 items-center gap-2 rounded-lg border border-border px-3 text-sm text-text-secondary transition hover:bg-surface-hover hover:text-text-primary focus-visible:outline-2 focus-visible:outline-focus-ring focus-visible:outline-offset-2 disabled:opacity-60"
          >
            <IconRefresh aria-hidden="true" size={16} />
            Actualizar
          </button>
        </div>
      </div>

      <output
        aria-live="polite"
        className="mt-4 block text-sm text-text-secondary"
      >
        {error || notice || (isLoading ? "Cargando novedades…" : "")}
      </output>

      {accessUnavailable ? (
        <div className="mt-3 rounded-xl border border-border bg-surface-raised p-5 text-sm text-text-secondary">
          Las novedades no están disponibles para esta cuenta.
        </div>
      ) : items.length === 0 && !isLoading && !error ? (
        <div className="mt-3 rounded-xl border border-border bg-surface-raised p-5 text-sm text-text-secondary">
          {filter === "unread"
            ? "No tienes novedades sin leer."
            : "Todavía no tienes novedades."}
        </div>
      ) : items.length > 0 ? (
        <ul className="mt-3 divide-y divide-border rounded-xl border border-border bg-surface-raised">
          {items.map((item) => (
            <li
              key={item.id}
              className={`flex flex-wrap items-center justify-between gap-4 p-4 ${item.read_at === null ? "bg-surface-hover/40" : ""}`}
            >
              <div className="min-w-0 flex-1">
                <p className="truncate font-medium text-text-primary">
                  {item.unavailable || item.task_title === null
                    ? "Tarea no disponible"
                    : item.task_title}
                </p>
                <p className="mt-1 text-sm text-text-secondary">
                  {item.actor_name} ·{" "}
                  {taskNotificationReasonLabel(item.reason_codes)}
                </p>
                <time
                  dateTime={item.occurred_at}
                  className="mt-1 block text-text-muted text-xs"
                >
                  {formatTimestamp(item.occurred_at)}
                </time>
                {item.read_at !== null ? (
                  <span className="sr-only">Leída</span>
                ) : (
                  <span className="sr-only">Sin leer</span>
                )}
              </div>
              <div className="flex flex-wrap gap-2">
                {!item.unavailable && item.task_title !== null ? (
                  <button
                    type="button"
                    onClick={() => void open(item)}
                    disabled={busyId === item.id}
                    className="inline-flex min-h-10 items-center gap-2 rounded-lg bg-accent px-3 font-medium text-accent-foreground text-sm transition hover:brightness-95 focus-visible:outline-2 focus-visible:outline-focus-ring focus-visible:outline-offset-2 disabled:opacity-60"
                  >
                    Abrir tarea
                    <IconArrowUpRight aria-hidden="true" size={16} />
                  </button>
                ) : null}
                {item.read_at === null ? (
                  <button
                    type="button"
                    onClick={() => void markRead(item)}
                    disabled={busyId === item.id}
                    className="min-h-10 rounded-lg border border-border px-3 text-sm text-text-secondary transition hover:bg-surface-hover hover:text-text-primary focus-visible:outline-2 focus-visible:outline-focus-ring focus-visible:outline-offset-2 disabled:opacity-60"
                  >
                    Marcar como leída
                  </button>
                ) : null}
              </div>
            </li>
          ))}
        </ul>
      ) : null}

      {hasMore && !accessUnavailable ? (
        <div className="mt-4 text-center">
          <button
            type="button"
            onClick={() => void refresh(filter, true)}
            disabled={isLoading || cursor === null}
            className="min-h-11 rounded-lg border border-border px-4 font-medium text-sm text-text-secondary transition hover:bg-surface-hover hover:text-text-primary focus-visible:outline-2 focus-visible:outline-focus-ring focus-visible:outline-offset-2 disabled:opacity-60"
          >
            Cargar novedades anteriores
          </button>
        </div>
      ) : null}
    </section>
  );
}
