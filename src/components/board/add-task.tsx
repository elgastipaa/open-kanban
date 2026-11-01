"use client";

import { IconPlus } from "@tabler/icons-react";
import { useEffect, useId, useRef, useState } from "react";
import { useDevice } from "@/hooks/use-device";
import { TaskCaptureError, type TaskCaptureErrorReason } from "@/lib/db/tasks";
import { taskCaptureFailureTransition } from "@/lib/task-capture-state";
import { cn, generateUUID } from "@/lib/utils";

interface AddTaskProps {
  columnId: string;
  onAdd: (
    title: string,
    operationId: string,
    reconcileFirst: boolean,
    columnId: string,
  ) => Promise<void>;
}

const reconciliationReasons: TaskCaptureErrorReason[] = [
  "uncertain",
  "expired_unknown",
  "unavailable",
];

function errorMessage(reason: TaskCaptureErrorReason | null): string | null {
  switch (reason) {
    case "uncertain":
      return "No pudimos confirmar si se guardó esta tarea. Reconciliá antes de continuar.";
    case "expired_unknown":
      return "El recibo venció y no pudimos confirmar el resultado. No se reintentó la captura.";
    case "unavailable":
      return "El tablero o la columna no están disponibles. Conservamos el borrador.";
    case "rejected":
      return "No se pudo añadir la tarea. Conservamos el borrador.";
    case "conflict":
      return "Esta clave ya pertenece a otra captura. Conservamos el borrador; asignale una clave nueva para continuar.";
    case "access_denied":
      return "Ya no tenés acceso para crear tareas en este tablero. Eliminamos el borrador.";
    default:
      return null;
  }
}

export function AddTask({ columnId, onAdd }: AddTaskProps) {
  const [isOpen, setIsOpen] = useState(false);
  const [title, setTitle] = useState("");
  const [operationId, setOperationId] = useState(() => generateUUID());
  const [operationColumnId, setOperationColumnId] = useState(columnId);
  const [pending, setPending] = useState(false);
  const [errorReason, setErrorReason] = useState<TaskCaptureErrorReason | null>(
    null,
  );
  const pendingRef = useRef(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const accessDeniedRef = useRef<HTMLParagraphElement>(null);
  const { isMobile } = useDevice();
  const taskCaptureMessageId = useId();
  const reconciliationRequired =
    errorReason !== null && reconciliationReasons.includes(errorReason);
  const payloadConflict = errorReason === "conflict";
  const accessDenied = errorReason === "access_denied";
  const message = errorMessage(errorReason);

  useEffect(() => {
    if (isOpen) inputRef.current?.focus();
  }, [isOpen]);

  useEffect(() => {
    if (accessDenied) accessDeniedRef.current?.focus();
  }, [accessDenied]);

  useEffect(() => {
    if (!title && !pending && !reconciliationRequired) {
      setOperationColumnId(columnId);
    }
  }, [columnId, pending, reconciliationRequired, title]);

  async function submit(reconcileFirst = reconciliationRequired) {
    if (pendingRef.current) return;
    const trimmed = title.trim();
    if (!trimmed) {
      inputRef.current?.focus();
      return;
    }

    pendingRef.current = true;
    setPending(true);
    setErrorReason(null);
    try {
      await onAdd(trimmed, operationId, reconcileFirst, operationColumnId);
      setTitle("");
      setOperationId(generateUUID());
      setOperationColumnId(columnId);
      setErrorReason(null);
      inputRef.current?.focus();
    } catch (error) {
      const transition = taskCaptureFailureTransition(
        title,
        error instanceof TaskCaptureError ? error.reason : "uncertain",
      );
      setTitle(transition.title);
      setErrorReason(transition.errorReason);
      if (transition.removeComposer) {
        setOperationId(generateUUID());
        setOperationColumnId(columnId);
        setIsOpen(false);
        return;
      }
      inputRef.current?.focus();
    } finally {
      pendingRef.current = false;
      setPending(false);
    }
  }

  function discardDraft() {
    setTitle("");
    setOperationId(generateUUID());
    setOperationColumnId(columnId);
    setErrorReason(null);
    inputRef.current?.focus();
  }

  function assignNewOperationId() {
    if (pendingRef.current || !payloadConflict) return;
    setOperationId(generateUUID());
    setErrorReason(null);
    inputRef.current?.focus();
  }

  if (accessDenied) {
    return (
      <p
        ref={accessDeniedRef}
        role="alert"
        tabIndex={-1}
        className="rounded-xl border border-border bg-surface-raised p-3 text-sm text-text-muted"
      >
        {message}
      </p>
    );
  }

  if (!isOpen) {
    return (
      <button
        type="button"
        onClick={() => setIsOpen(true)}
        className={cn(
          "flex w-full cursor-pointer items-center justify-center gap-2 rounded-xl px-4 py-2.5 font-bold text-sm shadow-sm transition-all hover:opacity-90 active:scale-[0.98]",
          isMobile ? "bg-accent text-accent-foreground" : "text-text-muted",
        )}
      >
        <IconPlus size={18} stroke={2.5} />
        Añadir tarea
      </button>
    );
  }

  return (
    <div className="rounded-xl border border-accent/30 bg-surface-overlay p-1 shadow-sm transition-all focus-within:border-accent focus-within:ring-4 focus-within:ring-accent/10">
      <div className="flex items-center gap-1 rounded-lg bg-surface-raised p-1">
        <input
          ref={inputRef}
          value={title}
          readOnly={pending || reconciliationRequired || payloadConflict}
          onChange={(event) => {
            setTitle(event.target.value);
            if (errorReason === "rejected") {
              setOperationId(generateUUID());
              setOperationColumnId(columnId);
              setErrorReason(null);
            }
          }}
          onKeyDown={(event) => {
            if (event.key === "Enter") {
              event.preventDefault();
              if (!payloadConflict) void submit();
            }
            if (event.key === "Escape" && !pending) setIsOpen(false);
          }}
          placeholder="¿Qué hay que hacer?"
          aria-label="Título de la tarea"
          aria-describedby={message ? taskCaptureMessageId : undefined}
          className="w-full flex-1 bg-transparent px-3 py-1.5 font-medium text-sm text-text-primary placeholder-text-muted outline-none read-only:opacity-70"
        />
        <button
          type="button"
          onClick={() => {
            if (payloadConflict) {
              assignNewOperationId();
              return;
            }
            void submit();
          }}
          disabled={pending || (!title.trim() && !payloadConflict)}
          className="shrink-0 rounded-md bg-accent px-3 py-1.5 font-semibold text-accent-foreground text-sm disabled:cursor-not-allowed disabled:opacity-50"
        >
          {pending
            ? "Guardando…"
            : reconciliationRequired
              ? "Reconciliar"
              : payloadConflict
                ? "Asignar clave nueva"
                : "Añadir"}
        </button>
      </div>
      {message ? (
        <output
          id={taskCaptureMessageId}
          aria-live="polite"
          className="px-3 py-2 text-text-muted text-xs"
        >
          <p>{message}</p>
          {payloadConflict || reconciliationRequired ? (
            <button
              type="button"
              onClick={discardDraft}
              className="mt-2 cursor-pointer font-semibold text-accent underline"
            >
              Descartar borrador sin reintentar
            </button>
          ) : null}
        </output>
      ) : null}
      {operationColumnId !== columnId ? (
        <p className="px-3 py-1 text-text-muted text-xs">
          El borrador sigue asignado a la columna donde empezó.
        </p>
      ) : null}
    </div>
  );
}
