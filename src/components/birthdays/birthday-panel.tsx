"use client";

import { IconCake, IconPencil, IconPlus, IconTrash } from "@tabler/icons-react";
import Link from "next/link";
import {
  type FormEvent,
  useCallback,
  useEffect,
  useId,
  useMemo,
  useState,
} from "react";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { Modal } from "@/components/ui/modal";
import {
  type BoardBirthday,
  createBirthday,
  type DeletedBirthday,
  deleteBirthday,
  listBoardBirthdays,
  listDeletedBirthdays,
  listMyBirthdays,
  restoreBirthday,
  updateBirthday,
} from "@/lib/db/birthdays";
import { createClient } from "@/lib/supabase/client";
import { generateUUID } from "@/lib/utils";

type BirthdayMode =
  | { type: "board"; boardId: string; slug: string; timeZone: string }
  | { type: "series"; boardId: string | null };

interface BirthdayDraft {
  name: string;
  month: string;
  day: string;
  advanceDays: string;
  operationId: string;
}

const emptyDraft = (): BirthdayDraft => ({
  name: "",
  month: "",
  day: "",
  advanceDays: "",
  operationId: generateUUID(),
});

function formatDate(value: string) {
  const date = new Date(`${value.slice(0, 10)}T00:00:00Z`);
  return new Intl.DateTimeFormat("es-AR", {
    dateStyle: "medium",
    timeZone: "UTC",
  }).format(date);
}

function localCalendarDay(timeZone: string, instant: Date) {
  return new Intl.DateTimeFormat("en-CA", {
    calendar: "gregory",
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(instant);
}

function validAnnualDate(month: number, day: number) {
  if (!Number.isInteger(month) || !Number.isInteger(day)) return false;
  const date = new Date(Date.UTC(2000, month - 1, day));
  return (
    date.getUTCFullYear() === 2000 &&
    date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day
  );
}

function parseAdvance(value: string): number | null | undefined {
  if (value.trim() === "") return null;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0 || parsed > 366) {
    return undefined;
  }
  return parsed;
}

function errorForStatus(status: string) {
  switch (status) {
    case "conflict":
      return "Este cumpleaños cambió. Actualizamos la lista; revisá el dato antes de guardar de nuevo.";
    case "expired":
      return "Ya venció el plazo de recuperación de este cumpleaños.";
    case "expired_unknown":
      return "No se pudo confirmar si este cumpleaños llegó a guardarse. Revisá Cumpleaños en Series antes de iniciar otra alta.";
    case "unavailable":
      return "El tablero o el cumpleaños ya no están disponibles con tu acceso actual.";
    default:
      return "No se pudo confirmar el cambio. Conservamos el formulario para que puedas revisar e intentar de nuevo.";
  }
}

interface BirthdayPanelProps {
  mode: BirthdayMode;
}

export function BirthdayPanel({ mode }: BirthdayPanelProps) {
  const supabase = useMemo(() => createClient(), []);
  const [birthdays, setBirthdays] = useState<BoardBirthday[]>([]);
  const [deletedBirthdays, setDeletedBirthdays] = useState<DeletedBirthday[]>(
    [],
  );
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [editorOpen, setEditorOpen] = useState(false);
  const [editingBirthday, setEditingBirthday] = useState<BoardBirthday | null>(
    null,
  );
  const [deleteTarget, setDeleteTarget] = useState<BoardBirthday | null>(null);
  const [draft, setDraft] = useState<BirthdayDraft>(() => emptyDraft());
  const [pending, setPending] = useState(false);
  const [createResultExpired, setCreateResultExpired] = useState(false);
  const [restoringId, setRestoringId] = useState<string | null>(null);
  const nameId = useId();
  const monthId = useId();
  const dayId = useId();
  const advanceId = useId();
  const errorId = useId();
  const isSeries = mode.type === "series";
  const modeType = mode.type;
  const modeBoardId = mode.boardId;
  const modeSlug = mode.type === "board" ? mode.slug : null;
  const boardTimeZone = mode.type === "board" ? mode.timeZone : null;
  const timeZones = useMemo(() => {
    const fromBirthdays = birthdays.map((birthday) => birthday.board_time_zone);
    const selectedBoardZone = boardTimeZone ? [boardTimeZone] : [];
    return Array.from(new Set([...fromBirthdays, ...selectedBoardZone]));
  }, [birthdays, boardTimeZone]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: A zone change must recreate the callback so its refresh effect fetches server-resolved dates again.
  const refresh = useCallback(async () => {
    setError(null);
    try {
      const [active, deleted] = await Promise.all([
        modeType === "board"
          ? listBoardBirthdays(supabase, modeSlug ?? "")
          : listMyBirthdays(supabase, modeBoardId),
        modeType === "series"
          ? listDeletedBirthdays(supabase, modeBoardId)
          : null,
      ]);
      if (active.status !== "available") {
        setBirthdays([]);
        setDeletedBirthdays([]);
        setError("No se pudo confirmar el acceso a estos cumpleaños.");
        return;
      }
      setBirthdays(active.birthdays);
      if (deleted && deleted.status === "available") {
        setDeletedBirthdays(deleted.birthdays);
      } else {
        setDeletedBirthdays([]);
      }
    } catch {
      setError(
        "No se pudieron cargar los cumpleaños. Reintentá desde esta pantalla.",
      );
    } finally {
      setLoading(false);
    }
  }, [boardTimeZone, modeBoardId, modeSlug, modeType, supabase]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  useEffect(() => {
    if (loading || timeZones.length === 0) return;
    const lastObservedDay = new Map(
      timeZones.map((timeZone) => [
        timeZone,
        localCalendarDay(timeZone, new Date()),
      ]),
    );
    const timer = window.setInterval(() => {
      if (document.visibilityState !== "visible") return;
      const now = new Date();
      const changed = timeZones.some((timeZone) => {
        const nextDay = localCalendarDay(timeZone, now);
        if (lastObservedDay.get(timeZone) === nextDay) return false;
        lastObservedDay.set(timeZone, nextDay);
        return true;
      });
      if (changed) void refresh();
    }, 60_000);
    const handleVisible = () => {
      if (document.visibilityState === "visible") void refresh();
    };
    document.addEventListener("visibilitychange", handleVisible);
    return () => {
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", handleVisible);
    };
  }, [loading, refresh, timeZones]);

  function openCreate() {
    setEditingBirthday(null);
    setDraft(emptyDraft());
    setError(null);
    setNotice(null);
    setCreateResultExpired(false);
    setEditorOpen(true);
  }

  function openEdit(birthday: BoardBirthday) {
    setEditingBirthday(birthday);
    setDraft({
      name: birthday.name,
      month: String(birthday.birth_month),
      day: String(birthday.birth_day),
      advanceDays:
        birthday.advance_days === null ? "" : String(birthday.advance_days),
      operationId: generateUUID(),
    });
    setError(null);
    setNotice(null);
    setCreateResultExpired(false);
    setEditorOpen(true);
  }

  async function saveBirthday(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (pending || createResultExpired) return;
    const name = draft.name.trim();
    const month = Number(draft.month);
    const day = Number(draft.day);
    const advanceDays = parseAdvance(draft.advanceDays);
    if (!name || name.length > 100) {
      setError("Escribe un nombre de hasta 100 caracteres.");
      return;
    }
    if (!validAnnualDate(month, day)) {
      setError("Revisá el día y el mes. Podés guardar el 29 de febrero.");
      return;
    }
    if (advanceDays === undefined) {
      setError("La anticipación debe ser un número entero entre 0 y 366 días.");
      return;
    }
    if (mode.type !== "board" && !editingBirthday) {
      setError(
        "Para crear un cumpleaños, abrí primero el tablero correspondiente.",
      );
      return;
    }

    setPending(true);
    setError(null);
    try {
      const result = editingBirthday
        ? await updateBirthday(supabase, {
            operationId: draft.operationId,
            slug: editingBirthday.board_slug,
            birthdayId: editingBirthday.id,
            expectedVersion: editingBirthday.version,
            name,
            birthMonth: month,
            birthDay: day,
            advanceDays,
          })
        : await createBirthday(supabase, {
            operationId: draft.operationId,
            slug: mode.type === "board" ? mode.slug : "",
            name,
            birthMonth: month,
            birthDay: day,
            advanceDays,
          });
      if (result.status !== "confirmed") {
        setError(errorForStatus(result.status));
        if (result.status === "expired_unknown" && !editingBirthday) {
          setCreateResultExpired(true);
        }
        if (
          result.status === "conflict" ||
          result.status === "unavailable" ||
          result.status === "expired_unknown"
        ) {
          await refresh();
        }
        return;
      }
      setEditorOpen(false);
      setEditingBirthday(null);
      setNotice(
        editingBirthday
          ? "Se guardaron los cambios del cumpleaños."
          : "Se agregó el cumpleaños al tablero.",
      );
      setDraft(emptyDraft());
      await refresh();
    } catch {
      setError(errorForStatus("uncertain"));
    } finally {
      setPending(false);
    }
  }

  async function confirmDelete() {
    if (!deleteTarget || pending) return;
    setPending(true);
    setError(null);
    try {
      const result = await deleteBirthday(supabase, {
        operationId: generateUUID(),
        slug: deleteTarget.board_slug,
        birthdayId: deleteTarget.id,
        expectedVersion: deleteTarget.version,
      });
      if (result.status !== "confirmed") {
        setError(errorForStatus(result.status));
        if (result.status === "conflict" || result.status === "unavailable") {
          await refresh();
        }
        return;
      }
      setDeleteTarget(null);
      setNotice(
        "Se eliminó el cumpleaños. Podés recuperarlo desde Series durante 7 días.",
      );
      await refresh();
    } catch {
      setError(errorForStatus("uncertain"));
    } finally {
      setPending(false);
    }
  }

  async function restoreDeletedBirthday(birthday: DeletedBirthday) {
    if (!birthday.can_restore || restoringId) return;
    setRestoringId(birthday.id);
    setError(null);
    try {
      const result = await restoreBirthday(supabase, {
        operationId: generateUUID(),
        slug: birthday.board_slug,
        birthdayId: birthday.id,
      });
      if (result.status !== "confirmed") {
        setError(errorForStatus(result.status));
        return;
      }
      setNotice("Se recuperó el cumpleaños en el tablero.");
      await refresh();
    } catch {
      setError(errorForStatus("uncertain"));
    } finally {
      setRestoringId(null);
    }
  }

  return (
    <section
      aria-labelledby={
        isSeries ? "series-birthdays-title" : "board-birthdays-title"
      }
      className={
        isSeries
          ? "mt-8 rounded-2xl border border-border bg-surface-raised p-4 sm:p-5"
          : "shrink-0 border-border border-b bg-surface-raised px-4 py-3 md:px-6"
      }
    >
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <IconCake size={18} aria-hidden="true" className="text-accent" />
          <h2
            id={isSeries ? "series-birthdays-title" : "board-birthdays-title"}
            className="font-semibold text-sm text-text-primary"
          >
            {isSeries ? "Cumpleaños de tus tableros" : "Cumpleaños"}
          </h2>
          {isSeries ? (
            <span className="text-text-muted text-xs">
              Sin completado · fecha local de cada tablero
            </span>
          ) : null}
        </div>
        {mode.type === "board" ? (
          <div className="flex items-center gap-2">
            <Link
              href={`/series?board=${encodeURIComponent(mode.boardId)}`}
              className="rounded-md px-2 py-1 text-text-secondary text-xs underline-offset-4 hover:text-text-primary hover:underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
            >
              Ver en Series
            </Link>
            <Button variant="ghost" size="sm" onClick={openCreate}>
              <IconPlus size={16} aria-hidden="true" />
              Agregar cumpleaños
            </Button>
          </div>
        ) : null}
      </div>

      {notice ? (
        <output
          className="mt-2 block text-sm text-status-connected"
          aria-live="polite"
        >
          {notice}
        </output>
      ) : null}
      {error ? (
        <p className="mt-2 text-priority-urgent text-sm" role="alert">
          {error}
        </p>
      ) : null}

      {loading ? (
        <p className="mt-3 text-sm text-text-muted" aria-live="polite">
          Cargando cumpleaños…
        </p>
      ) : birthdays.length === 0 && deletedBirthdays.length === 0 ? (
        <p className="mt-3 text-sm text-text-secondary">
          {isSeries
            ? "Todavía no hay cumpleaños en tus tableros."
            : "No hay cumpleaños visibles ahora. Los que estén fuera de su ventana siguen disponibles en Series."}
        </p>
      ) : birthdays.length === 0 ? (
        <p className="mt-3 text-sm text-text-secondary">
          No hay cumpleaños visibles en este momento. Los cumpleaños fuera de su
          ventana se encuentran en Series.
        </p>
      ) : (
        <ul
          className={
            isSeries
              ? "mt-4 grid gap-2 sm:grid-cols-2"
              : "mt-2 flex max-w-full gap-2 overflow-x-auto pb-1"
          }
        >
          {birthdays.map((birthday) => (
            <li
              key={birthday.id}
              className={
                isSeries
                  ? "flex min-w-0 items-center justify-between gap-3 rounded-lg border border-border bg-surface-base p-3"
                  : "shrink-0"
              }
            >
              {isSeries ? (
                <div className="min-w-0">
                  <span className="block text-text-muted text-xs">
                    {birthday.board_name} ·{" "}
                    {birthday.visible
                      ? "Visible en el tablero"
                      : "Fuera de ventana"}
                  </span>
                  <span className="block truncate font-medium text-sm text-text-primary">
                    {birthday.name} · {formatDate(birthday.next_on)}
                  </span>
                  {birthday.advance_days !== null ? (
                    <span className="block text-text-muted text-xs">
                      Aparece {birthday.advance_days} días antes ·{" "}
                      {birthday.board_time_zone}
                    </span>
                  ) : null}
                </div>
              ) : null}
              {isSeries ? (
                <div className="flex shrink-0 items-center gap-1">
                  <button
                    type="button"
                    onClick={() => openEdit(birthday)}
                    aria-label={`Editar cumpleaños ${birthday.name}`}
                    title="Editar cumpleaños"
                    className="rounded-md p-2 text-text-secondary hover:bg-surface-overlay hover:text-text-primary focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
                  >
                    <IconPencil size={16} aria-hidden="true" />
                  </button>
                  <button
                    type="button"
                    onClick={() => setDeleteTarget(birthday)}
                    aria-label={`Eliminar cumpleaños ${birthday.name}`}
                    title="Eliminar cumpleaños"
                    className="rounded-md p-2 text-text-secondary hover:bg-surface-overlay hover:text-priority-urgent focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
                  >
                    <IconTrash size={16} aria-hidden="true" />
                  </button>
                </div>
              ) : (
                <button
                  type="button"
                  onClick={() => openEdit(birthday)}
                  aria-label={`Abrir cumpleaños ${birthday.name}`}
                  title="Ver o editar cumpleaños"
                  className="max-w-64 rounded-lg border border-border bg-surface-base px-3 py-2 text-left hover:border-accent focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
                >
                  <span className="block truncate font-medium text-sm text-text-primary">
                    {birthday.name}
                  </span>
                  <span className="block text-text-secondary text-xs">
                    {formatDate(birthday.next_on)}
                  </span>
                </button>
              )}
            </li>
          ))}
        </ul>
      )}

      {isSeries && deletedBirthdays.length > 0 ? (
        <section aria-labelledby="deleted-birthdays-title" className="mt-6">
          <h3 id="deleted-birthdays-title" className="font-medium text-sm">
            Cumpleaños eliminados recuperables
          </h3>
          <ul className="mt-2 flex flex-col gap-2">
            {deletedBirthdays.map((birthday) => (
              <li
                key={birthday.id}
                className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-border p-3"
              >
                <div>
                  <span className="block font-medium text-sm">
                    {birthday.name}
                  </span>
                  <span className="block text-text-secondary text-xs">
                    {birthday.board_name} · Recuperable hasta{" "}
                    {formatDate(birthday.expires_at)}
                  </span>
                </div>
                <Button
                  variant="ghost"
                  size="sm"
                  disabled={
                    !birthday.can_restore || restoringId === birthday.id
                  }
                  onClick={() => void restoreDeletedBirthday(birthday)}
                >
                  {restoringId === birthday.id ? "Recuperando…" : "Recuperar"}
                </Button>
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      <Modal
        open={editorOpen}
        onClose={() => {
          if (!pending) setEditorOpen(false);
        }}
        title={editingBirthday ? "Cumpleaños" : "Agregar cumpleaños"}
        fullScreenMobile
      >
        <form className="flex flex-col gap-4" onSubmit={saveBirthday}>
          {editingBirthday ? (
            <div className="rounded-lg bg-surface-raised px-3 py-2 text-sm text-text-secondary">
              Próximo cumpleaños: {formatDate(editingBirthday.next_on)} · zona{" "}
              {editingBirthday.board_time_zone}
            </div>
          ) : (
            <p className="text-sm text-text-secondary">
              Es una fecha anual del tablero, no una tarea para completar.
            </p>
          )}
          <div className="flex flex-col gap-1.5">
            <label htmlFor={nameId} className="font-medium text-sm">
              Nombre
            </label>
            <input
              id={nameId}
              value={draft.name}
              onChange={(event) =>
                setDraft({ ...draft, name: event.target.value })
              }
              maxLength={100}
              autoComplete="off"
              aria-invalid={Boolean(error)}
              aria-describedby={error ? errorId : undefined}
              className="h-11 rounded-md border border-border bg-surface-base px-3 text-base text-text-primary outline-none focus:border-accent"
            />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="flex flex-col gap-1.5">
              <label htmlFor={dayId} className="font-medium text-sm">
                Día
              </label>
              <input
                id={dayId}
                type="number"
                inputMode="numeric"
                min={1}
                max={31}
                step={1}
                value={draft.day}
                onChange={(event) =>
                  setDraft({ ...draft, day: event.target.value })
                }
                aria-invalid={Boolean(error)}
                aria-describedby={error ? errorId : undefined}
                className="h-11 rounded-md border border-border bg-surface-base px-3 text-base text-text-primary outline-none focus:border-accent"
              />
            </div>
            <div className="flex flex-col gap-1.5">
              <label htmlFor={monthId} className="font-medium text-sm">
                Mes
              </label>
              <input
                id={monthId}
                type="number"
                inputMode="numeric"
                min={1}
                max={12}
                step={1}
                value={draft.month}
                onChange={(event) =>
                  setDraft({ ...draft, month: event.target.value })
                }
                aria-invalid={Boolean(error)}
                aria-describedby={error ? errorId : undefined}
                className="h-11 rounded-md border border-border bg-surface-base px-3 text-base text-text-primary outline-none focus:border-accent"
              />
            </div>
          </div>
          <div className="flex flex-col gap-1.5">
            <label htmlFor={advanceId} className="font-medium text-sm">
              Mostrar con anticipación (días)
            </label>
            <input
              id={advanceId}
              type="number"
              inputMode="numeric"
              min={0}
              max={366}
              step={1}
              value={draft.advanceDays}
              onChange={(event) =>
                setDraft({ ...draft, advanceDays: event.target.value })
              }
              aria-describedby={`${advanceId}-help${error ? ` ${errorId}` : ""}`}
              className="h-11 rounded-md border border-border bg-surface-base px-3 text-base text-text-primary outline-none focus:border-accent"
            />
            <p id={`${advanceId}-help`} className="text-text-muted text-xs">
              Dejalo vacío para verlo todo el año. Podés elegir hasta 366 días:
              aparece desde esa fecha hasta el cumpleaños inclusive; fuera de la
              ventana sigue en Series.
            </p>
          </div>
          {error ? (
            <p
              id={errorId}
              className="text-priority-urgent text-sm"
              role="alert"
            >
              {error}
            </p>
          ) : null}
          {editingBirthday ? (
            <div className="flex flex-wrap items-center justify-between gap-2">
              <Button
                type="button"
                variant="danger"
                onClick={() => {
                  setDeleteTarget(editingBirthday);
                  setEditorOpen(false);
                }}
                disabled={pending}
              >
                <IconTrash size={16} aria-hidden="true" />
                Eliminar
              </Button>
              <div className="flex justify-end gap-2">
                <Button
                  type="button"
                  variant="ghost"
                  onClick={() => setEditorOpen(false)}
                  disabled={pending}
                >
                  Cancelar
                </Button>
                <Button type="submit" disabled={pending}>
                  {pending ? "Guardando…" : "Guardar cambios"}
                </Button>
              </div>
            </div>
          ) : (
            <div className="flex justify-end gap-2">
              <Button
                type="button"
                variant="ghost"
                onClick={() => setEditorOpen(false)}
                disabled={pending}
              >
                Cancelar
              </Button>
              <Button type="submit" disabled={pending || createResultExpired}>
                {pending ? "Guardando…" : "Agregar cumpleaños"}
              </Button>
            </div>
          )}
        </form>
      </Modal>

      <ConfirmDialog
        open={deleteTarget !== null}
        onClose={() => {
          if (!pending) setDeleteTarget(null);
        }}
        onConfirm={() => void confirmDelete()}
        title="¿Eliminar este cumpleaños?"
        description="Se quitará del tablero y podrás recuperarlo desde Series durante 7 días. La fecha no se convierte en una tarea."
        confirmLabel={pending ? "Eliminando…" : "Eliminar cumpleaños"}
        cancelLabel="Conservar cumpleaños"
        loading={pending}
      />
    </section>
  );
}
