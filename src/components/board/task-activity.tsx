"use client";

import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { listTaskActivity } from "@/lib/db/task-activity";
import { createClient } from "@/lib/supabase/client";
import {
  describeTaskActivityEvent,
  taskActivityActorLabel,
} from "@/lib/task-activity-state";
import type {
  TaskActivityCursor,
  TaskActivityEvent,
  TaskActivityPage,
} from "@/lib/types";

interface TaskActivityProps {
  slug: string;
  taskId: string;
  actorId: string;
  timeZone: string;
  refreshSignal: number;
  isOnline: boolean;
  isSessionStale: boolean;
}

const pageSize = 30;

function formatActivityDate(value: string, timeZone: string): string {
  const date = new Date(value);
  if (!Number.isFinite(date.valueOf())) return "Fecha no disponible";
  try {
    return new Intl.DateTimeFormat("es-AR", {
      dateStyle: "medium",
      timeStyle: "short",
      timeZone,
    }).format(date);
  } catch {
    return new Intl.DateTimeFormat("es-AR", {
      dateStyle: "medium",
      timeStyle: "short",
    }).format(date);
  }
}

export function TaskActivity({
  slug,
  taskId,
  actorId,
  timeZone,
  refreshSignal,
  isOnline,
  isSessionStale,
}: TaskActivityProps) {
  const [events, setEvents] = useState<TaskActivityEvent[]>([]);
  const [status, setStatus] = useState<TaskActivityPage["status"] | null>(null);
  const [cursor, setCursor] = useState<TaskActivityCursor | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [error, setError] = useState("");
  const [retryVersion, setRetryVersion] = useState(0);
  const requestGenerationRef = useRef(0);
  const requestContextRef = useRef("");

  useEffect(() => {
    const requestContext = [
      actorId,
      slug,
      taskId,
      refreshSignal,
      retryVersion,
    ].join(":");
    requestContextRef.current = requestContext;
    const generation = ++requestGenerationRef.current;
    let active = true;
    setEvents([]);
    setStatus(null);
    setCursor(null);
    setHasMore(false);
    setError("");
    setIsLoading(true);
    setIsLoadingMore(false);

    if (!isOnline || isSessionStale) {
      setError(
        isSessionStale
          ? "Revisa tu acceso antes de consultar la actividad."
          : "Conéctate para cargar la actividad de la tarea.",
      );
      setIsLoading(false);
      return () => {
        active = false;
        if (requestGenerationRef.current === generation) {
          requestGenerationRef.current += 1;
        }
      };
    }

    async function loadInitialPage() {
      try {
        const page = await listTaskActivity(createClient(), slug, taskId, {
          limit: pageSize,
          cursor: null,
        });
        if (!active || requestGenerationRef.current !== generation) return;
        if (page.status === "unavailable") {
          setEvents([]);
          setStatus("unavailable");
          return;
        }
        applyPage(page);
      } catch {
        if (!active || requestGenerationRef.current !== generation) return;
        setError("No se pudo cargar la actividad. Inténtalo de nuevo.");
      } finally {
        if (active && requestGenerationRef.current === generation) {
          setIsLoading(false);
        }
      }
    }

    function applyPage(
      page: Extract<TaskActivityPage, { status: "available" }>,
    ) {
      setStatus("available");
      setError("");
      setEvents(page.events);
      setCursor(page.next_cursor);
      setHasMore(page.has_more);
    }

    void loadInitialPage();
    return () => {
      active = false;
      if (requestGenerationRef.current === generation) {
        requestGenerationRef.current += 1;
      }
    };
  }, [
    actorId,
    isOnline,
    isSessionStale,
    refreshSignal,
    retryVersion,
    slug,
    taskId,
  ]);

  async function loadMore() {
    if (!cursor || isLoadingMore || !hasMore || !isOnline || isSessionStale) {
      return;
    }
    const generation = requestGenerationRef.current;
    const requestContext = requestContextRef.current;
    setIsLoadingMore(true);
    setError("");
    try {
      const page = await listTaskActivity(createClient(), slug, taskId, {
        limit: pageSize,
        cursor,
      });
      if (
        requestGenerationRef.current !== generation ||
        requestContextRef.current !== requestContext
      ) {
        return;
      }
      if (page.status === "unavailable") {
        setEvents([]);
        setStatus("unavailable");
        setCursor(null);
        setHasMore(false);
        return;
      }
      setStatus("available");
      setEvents((current) => {
        const knownIds = new Set(current.map((event) => event.id));
        return [
          ...current,
          ...page.events.filter((event) => !knownIds.has(event.id)),
        ];
      });
      setCursor(page.next_cursor);
      setHasMore(page.has_more);
    } catch {
      if (
        requestGenerationRef.current === generation &&
        requestContextRef.current === requestContext
      ) {
        setError("No se pudo cargar más actividad. Inténtalo de nuevo.");
      }
    } finally {
      if (
        requestGenerationRef.current === generation &&
        requestContextRef.current === requestContext
      ) {
        setIsLoadingMore(false);
      }
    }
  }

  return (
    <section
      aria-labelledby="task-activity-heading"
      className="border-border border-t pt-4"
    >
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 id="task-activity-heading" className="font-semibold text-sm">
          Actividad
        </h3>
        <p className="text-text-muted text-xs">
          Se muestran los últimos 180 días.
        </p>
      </div>

      {isLoading && (
        <p aria-live="polite" className="mt-3 text-sm text-text-secondary">
          Cargando actividad…
        </p>
      )}

      {status === "unavailable" && (
        <p className="mt-3 text-sm text-text-secondary">
          La actividad de esta tarea no está disponible.
        </p>
      )}

      {error && (
        <div role="alert" className="mt-3 space-y-2">
          <p className="text-priority-urgent text-sm">{error}</p>
          <Button
            size="sm"
            variant="ghost"
            disabled={!isOnline || isSessionStale || isLoading}
            onClick={() => setRetryVersion((current) => current + 1)}
          >
            Reintentar
          </Button>
        </div>
      )}

      {!isLoading &&
        status === "available" &&
        events.length === 0 &&
        !error && (
          <p className="mt-3 text-sm text-text-secondary">
            No hay actividad en los últimos 180 días.
          </p>
        )}

      {status === "available" && events.length > 0 && (
        <ol className="mt-3 space-y-3">
          {events.map((event) => {
            const description = describeTaskActivityEvent(event);
            return (
              <li
                key={event.id}
                className="rounded-md border border-border bg-surface p-3"
              >
                <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
                  <p className="font-medium text-sm text-text-primary">
                    {taskActivityActorLabel(event.actor_type, event.actor_name)}
                  </p>
                  <time
                    dateTime={event.occurred_at}
                    className="text-text-muted text-xs"
                  >
                    {formatActivityDate(event.occurred_at, timeZone)}
                  </time>
                </div>
                <p className="mt-1 text-sm text-text-secondary">
                  <span className="font-medium">{description.label}:</span>{" "}
                  {description.value}
                </p>
              </li>
            );
          })}
        </ol>
      )}

      {hasMore && status === "available" && (
        <div className="mt-3">
          <Button
            size="sm"
            variant="ghost"
            disabled={isLoadingMore || !isOnline || isSessionStale}
            onClick={() => void loadMore()}
          >
            {isLoadingMore ? "Cargando…" : "Cargar más actividad"}
          </Button>
        </div>
      )}
    </section>
  );
}
