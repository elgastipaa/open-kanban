"use client";

import { useRouter } from "next/navigation";
import { useActionState, useEffect, useState } from "react";
import type { CreateBoardActionState } from "@/lib/auth-actions";
import { createOwnedBoard } from "@/lib/auth-actions";

const emptyState: CreateBoardActionState = { error: null };
const intentStorageKey = "openkanban:create-board-intent";

interface SavedIntent {
  name: string;
  timeZone: string;
  operationId: string;
  uncertain: boolean;
}

function readSavedIntent(): SavedIntent | null {
  try {
    const value = sessionStorage.getItem(intentStorageKey);
    if (!value) return null;
    const parsed = JSON.parse(value) as SavedIntent;
    if (
      typeof parsed.name === "string" &&
      typeof parsed.timeZone === "string" &&
      typeof parsed.operationId === "string" &&
      typeof parsed.uncertain === "boolean" &&
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
        parsed.operationId,
      )
    ) {
      return parsed;
    }
  } catch {
    // Session storage can be unavailable in restricted browser contexts.
  }
  return null;
}

function saveIntent(intent: SavedIntent) {
  try {
    sessionStorage.setItem(intentStorageKey, JSON.stringify(intent));
  } catch {
    // The current form state still keeps retries idempotent for this page.
  }
}

export function CreateBoardForm() {
  const router = useRouter();
  const [state, formAction, pending] = useActionState(
    createOwnedBoard,
    emptyState,
  );
  const [name, setName] = useState("");
  const [timeZone, setTimeZone] = useState("");
  const [operationId, setOperationId] = useState("");
  const [intentUncertain, setIntentUncertain] = useState(false);

  useEffect(() => {
    if (state.slug) {
      try {
        sessionStorage.removeItem(intentStorageKey);
      } catch {
        // Navigation can proceed without storage access.
      }
      router.push(`/${state.slug}`);
      return;
    }
    if (!state.error) return;

    if (state.editable) {
      setIntentUncertain(false);
      if (timeZone && operationId) {
        saveIntent({ name, timeZone, operationId, uncertain: false });
      }
    } else if (state.uncertain) {
      setIntentUncertain(true);
      if (timeZone && operationId) {
        saveIntent({ name, timeZone, operationId, uncertain: true });
      }
    }
  }, [state, router, name, timeZone, operationId]);

  useEffect(() => {
    let detectedTimeZone = "";
    try {
      detectedTimeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    } catch {
      detectedTimeZone = "";
    }
    if (!detectedTimeZone) return;

    const saved = readSavedIntent();
    const nextName = saved?.name ?? "";
    const keepSavedIntent =
      saved?.uncertain === true || saved?.timeZone === detectedTimeZone;
    const nextTimeZone = keepSavedIntent
      ? (saved?.timeZone ?? detectedTimeZone)
      : detectedTimeZone;
    const nextOperationId = keepSavedIntent
      ? (saved?.operationId ?? crypto.randomUUID())
      : crypto.randomUUID();
    setName(nextName);
    setTimeZone(nextTimeZone);
    setOperationId(nextOperationId);
    setIntentUncertain(saved?.uncertain === true);
    saveIntent({
      name: nextName,
      timeZone: nextTimeZone,
      operationId: nextOperationId,
      uncertain: saved?.uncertain === true,
    });
  }, []);

  function updateName(nextName: string) {
    setName(nextName);
    if (intentUncertain) return;
    const nextOperationId = crypto.randomUUID();
    setOperationId(nextOperationId);
    if (timeZone) {
      saveIntent({
        name: nextName,
        timeZone,
        operationId: nextOperationId,
        uncertain: false,
      });
    }
  }

  function handleSubmit() {
    setIntentUncertain(true);
    if (timeZone && operationId) {
      saveIntent({ name, timeZone, operationId, uncertain: true });
    }
  }

  return (
    <form
      action={formAction}
      onSubmit={handleSubmit}
      className="w-full max-w-md"
    >
      <label
        htmlFor="new-board-name"
        className="block font-medium text-sm text-text-primary"
      >
        Nombre del tablero
      </label>
      <div className="mt-2 flex flex-col gap-3 sm:flex-row">
        <input
          id="new-board-name"
          name="name"
          value={name}
          onChange={(event) => updateName(event.target.value)}
          readOnly={pending || intentUncertain || !operationId}
          maxLength={100}
          autoComplete="off"
          aria-required="true"
          aria-invalid={Boolean(state.error)}
          aria-describedby={state.error ? "create-board-error" : undefined}
          className="min-h-12 min-w-0 flex-1 rounded-xl border border-border bg-surface-raised px-4 py-3 text-text-primary outline-none transition focus:border-accent focus:ring-2 focus:ring-accent/20"
          placeholder="Por ejemplo, Casa"
        />
        <button
          type="submit"
          disabled={pending || !timeZone || !operationId}
          className="min-h-12 rounded-xl bg-white px-5 py-3 font-semibold text-neutral-950 transition hover:bg-neutral-200 disabled:cursor-wait disabled:opacity-60"
        >
          {pending
            ? "Creando…"
            : intentUncertain
              ? "Reintentar creación"
              : "Crear tablero"}
        </button>
      </div>
      <input type="hidden" name="time_zone" value={timeZone} />
      <input type="hidden" name="operation_id" value={operationId} />
      <p className="mt-2 text-text-muted text-xs" aria-live="polite">
        {timeZone
          ? `Zona horaria inicial: ${timeZone}`
          : "Detectando la zona horaria de este dispositivo…"}
      </p>
      {state.error ? (
        <p
          id="create-board-error"
          className="mt-3 text-red-300 text-sm"
          role="alert"
        >
          {state.error}
        </p>
      ) : null}
    </form>
  );
}
