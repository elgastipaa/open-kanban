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
import { BoardLabelBadge } from "@/components/labels/board-label-badge";
import { BoardLabelPicker } from "@/components/labels/board-label-picker";
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
import {
  getBoardLabelAssignments,
  listBoardLabels,
  setBirthdayLabels,
} from "@/lib/db/board-labels";
import { createClient } from "@/lib/supabase/client";
import type { BoardLabel } from "@/lib/types";
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

function sameLabelIds(left: string[], right: string[]) {
  return (
    left.length === right.length &&
    left.slice().sort().join("\u0000") === right.slice().sort().join("\u0000")
  );
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
  labelFilterIds?: string[];
  refreshSignal?: number;
  availableLabels?: BoardLabel[];
}

export function BirthdayPanel({
  mode,
  labelFilterIds = [],
  refreshSignal = 0,
  availableLabels = [],
}: BirthdayPanelProps) {
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
  const [selectedLabelIds, setSelectedLabelIds] = useState<string[]>([]);
  const [savedLabelIds, setSavedLabelIds] = useState<string[]>([]);
  const [latestLabelConflict, setLatestLabelConflict] = useState<
    BoardLabel[] | null
  >(null);
  const [showLabelCloseChoices, setShowLabelCloseChoices] = useState(false);
  const [pendingLabelAction, setPendingLabelAction] = useState<
    "close" | "delete" | null
  >(null);
  const [seriesLabelCatalogs, setSeriesLabelCatalogs] = useState<
    Record<string, BoardLabel[]>
  >({});
  const [labelsSaving, setLabelsSaving] = useState(false);
  const [labelsNotice, setLabelsNotice] = useState("");
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
  const labelsDirty =
    editingBirthday !== null && !sameLabelIds(selectedLabelIds, savedLabelIds);
  const timeZones = useMemo(() => {
    const fromBirthdays = birthdays.map((birthday) => birthday.board_time_zone);
    const selectedBoardZone = boardTimeZone ? [boardTimeZone] : [];
    return Array.from(new Set([...fromBirthdays, ...selectedBoardZone]));
  }, [birthdays, boardTimeZone]);
  const visibleBirthdays = useMemo(() => {
    if (mode.type !== "board" || labelFilterIds.length === 0) {
      return birthdays;
    }
    const selected = new Set(labelFilterIds);
    return birthdays.filter((birthday) =>
      birthday.labels?.some((label) => selected.has(label.id)),
    );
  }, [birthdays, labelFilterIds, mode.type]);

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
      if (modeType === "board") {
        const assignments = await getBoardLabelAssignments(
          supabase,
          modeSlug ?? "",
        );
        if (assignments.status !== "available") {
          setBirthdays([]);
          setDeletedBirthdays([]);
          setError("No se pudieron confirmar las etiquetas de este tablero.");
          return;
        }
        const labelsByBirthday = new Map(
          assignments.birthdays.map((assignment) => [
            assignment.birthday_id,
            assignment.labels,
          ]),
        );
        setBirthdays(
          active.birthdays.map((birthday) => ({
            ...birthday,
            labels: labelsByBirthday.get(birthday.id) ?? [],
          })),
        );
      } else {
        const boardEntries = Array.from(
          new Map(
            active.birthdays.map((birthday) => [
              birthday.board_id,
              { slug: birthday.board_slug },
            ]),
          ),
        );
        const boardReads = await Promise.all(
          boardEntries.map(async ([boardId, board]) => {
            try {
              const [assignments, catalog] = await Promise.all([
                getBoardLabelAssignments(supabase, board.slug),
                listBoardLabels(supabase, board.slug),
              ]);
              return { boardId, assignments, catalog };
            } catch {
              return null;
            }
          }),
        );
        const labelsByBirthday = new Map<string, BoardLabel[]>();
        const catalogsByBoard: Record<string, BoardLabel[]> = {};
        for (const boardRead of boardReads) {
          if (!boardRead || boardRead.assignments.status !== "available") {
            continue;
          }
          catalogsByBoard[boardRead.boardId] = boardRead.catalog;
          for (const assignment of boardRead.assignments.birthdays) {
            labelsByBirthday.set(assignment.birthday_id, assignment.labels);
          }
        }
        setSeriesLabelCatalogs(catalogsByBoard);
        setBirthdays(
          active.birthdays.map((birthday) => ({
            ...birthday,
            labels: labelsByBirthday.get(birthday.id) ?? [],
          })),
        );
      }
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
  }, [boardTimeZone, modeBoardId, modeSlug, modeType, refreshSignal, supabase]);

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
    setSelectedLabelIds([]);
    setSavedLabelIds([]);
    setLatestLabelConflict(null);
    setShowLabelCloseChoices(false);
    setPendingLabelAction(null);
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
    const labels = birthday.labels?.map((label) => label.id) ?? [];
    setSelectedLabelIds(labels);
    setSavedLabelIds(labels);
    setLatestLabelConflict(null);
    setShowLabelCloseChoices(false);
    setPendingLabelAction(null);
    setEditorOpen(true);
  }

  async function saveBirthdayLabelAssignments() {
    if (!editingBirthday || labelsSaving || selectedLabelIds.length > 10) {
      return false;
    }
    setLabelsSaving(true);
    setError(null);
    setLabelsNotice("");
    setNotice(null);
    try {
      const result = await setBirthdayLabels(
        supabase,
        editingBirthday.board_slug,
        editingBirthday.id,
        savedLabelIds,
        selectedLabelIds,
      );
      if (result.status !== "confirmed") {
        if (
          result.reason === "stale_selection" &&
          Array.isArray(result.labels)
        ) {
          setLatestLabelConflict(result.labels);
          setError(
            "Las etiquetas del cumpleaños cambiaron mientras editabas. Tu borrador sigue intacto; revisá la selección actual antes de volver a guardarlo.",
          );
          return false;
        }
        setError(
          result.reason === "too_many_labels"
            ? "El cumpleaños ya tiene 10 etiquetas. Actualizá la lista antes de guardar."
            : "No se pudo confirmar el cambio de etiquetas. Revisá el cumpleaños e intentá de nuevo.",
        );
        return false;
      }
      setSavedLabelIds(selectedLabelIds);
      setLatestLabelConflict(null);
      setLabelsNotice("Se guardaron las etiquetas del cumpleaños.");
      await refresh();
      return true;
    } catch {
      setError(
        "No se pudo confirmar el cambio. Revisá las etiquetas actuales antes de volver a intentar.",
      );
      return false;
    } finally {
      setLabelsSaving(false);
    }
  }

  function reviewLatestLabelConflict() {
    if (!latestLabelConflict) return;
    setSavedLabelIds(latestLabelConflict.map((label) => label.id));
    setLatestLabelConflict(null);
    setError(null);
    setLabelsNotice(
      "Actualizamos la base de comparación. Tu borrador sigue intacto; revisalo y guardá las etiquetas cuando termines.",
    );
  }

  function continueAfterLabelResolution() {
    const action = pendingLabelAction;
    setPendingLabelAction(null);
    setShowLabelCloseChoices(false);
    if (action === "delete" && editingBirthday) {
      setDeleteTarget(editingBirthday);
    }
    setEditorOpen(false);
  }

  async function saveLabelsAndContinue() {
    if (await saveBirthdayLabelAssignments()) continueAfterLabelResolution();
  }

  function discardLabelsAndContinue() {
    setSelectedLabelIds(savedLabelIds);
    setLatestLabelConflict(null);
    setError(null);
    continueAfterLabelResolution();
  }

  function cancelLabelActionAndKeepEditing() {
    setPendingLabelAction(null);
    setShowLabelCloseChoices(false);
  }

  function requestEditorClose() {
    if (pending || labelsSaving) return;
    if (labelsDirty) {
      setPendingLabelAction("close");
      setShowLabelCloseChoices(true);
      return;
    }
    setEditorOpen(false);
  }

  function requestBirthdayDelete() {
    if (!editingBirthday || pending || labelsSaving) return;
    if (labelsDirty) {
      setPendingLabelAction("delete");
      setShowLabelCloseChoices(true);
      return;
    }
    setDeleteTarget(editingBirthday);
    setEditorOpen(false);
  }

  const editorLabels =
    mode.type === "board"
      ? availableLabels
      : editingBirthday
        ? (seriesLabelCatalogs[editingBirthday.board_id] ?? [])
        : [];

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
      if (editingBirthday && labelsDirty) {
        setEditingBirthday({
          ...editingBirthday,
          name,
          birth_month: month,
          birth_day: day,
          advance_days: advanceDays,
          version: result.version ?? editingBirthday.version + 1,
        });
        setDraft((current) => ({
          ...current,
          name,
          month: String(month),
          day: String(day),
          advanceDays: advanceDays === null ? "" : String(advanceDays),
          operationId: generateUUID(),
        }));
        setNotice(
          "Se guardaron los datos del cumpleaños. Las etiquetas siguen como borrador y todavía puedes guardarlas o descartarlas.",
        );
        await refresh();
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
      ) : visibleBirthdays.length === 0 && deletedBirthdays.length === 0 ? (
        <p className="mt-3 text-sm text-text-secondary">
          {mode.type === "board" && labelFilterIds.length > 0
            ? "No hay cumpleaños visibles con estas etiquetas. Los que estén fuera de su ventana siguen disponibles en Series."
            : isSeries
              ? "Todavía no hay cumpleaños en tus tableros."
              : "No hay cumpleaños visibles ahora. Los que estén fuera de su ventana siguen disponibles en Series."}
        </p>
      ) : visibleBirthdays.length === 0 ? (
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
          {visibleBirthdays.map((birthday) => (
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
                  {birthday.labels && birthday.labels.length > 0 ? (
                    <ul
                      className="mt-1 flex flex-wrap gap-1"
                      aria-label={`Etiquetas de ${birthday.name}`}
                    >
                      {birthday.labels.map((label) => (
                        <li key={label.id}>
                          <BoardLabelBadge label={label} />
                        </li>
                      ))}
                    </ul>
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
                <div className="max-w-64">
                  <button
                    type="button"
                    onClick={() => openEdit(birthday)}
                    aria-label={`Abrir cumpleaños ${birthday.name}`}
                    title="Ver o editar cumpleaños"
                    className="w-full rounded-lg border border-border bg-surface-base px-3 py-2 text-left hover:border-accent focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
                  >
                    <span className="block truncate font-medium text-sm text-text-primary">
                      {birthday.name}
                    </span>
                    <span className="block text-text-secondary text-xs">
                      {formatDate(birthday.next_on)}
                    </span>
                  </button>
                  {birthday.labels && birthday.labels.length > 0 ? (
                    <ul
                      className="mt-1 flex flex-wrap gap-1"
                      aria-label={`Etiquetas de ${birthday.name}`}
                    >
                      {birthday.labels.map((label) => (
                        <li key={label.id}>
                          <BoardLabelBadge label={label} />
                        </li>
                      ))}
                    </ul>
                  ) : null}
                </div>
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
        onClose={requestEditorClose}
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
          {editingBirthday ? (
            <section className="space-y-2 border-border border-t pt-3">
              <BoardLabelPicker
                labels={editorLabels}
                selectedIds={selectedLabelIds}
                onChange={(next) => {
                  setSelectedLabelIds(next);
                  setLabelsNotice("");
                  setError(null);
                }}
                disabled={labelsSaving || pending}
                idPrefix={`birthday-label-${editingBirthday.id}`}
              />
              <div className="flex flex-wrap items-center justify-between gap-2">
                <p className="text-text-muted text-xs">
                  Las etiquetas se guardan por separado de la fecha.
                </p>
                <Button
                  type="button"
                  variant="ghost"
                  onClick={() => void saveBirthdayLabelAssignments()}
                  disabled={
                    labelsSaving ||
                    pending ||
                    latestLabelConflict !== null ||
                    selectedLabelIds.length > 10 ||
                    !labelsDirty
                  }
                >
                  {labelsSaving ? "Guardando…" : "Guardar etiquetas"}
                </Button>
              </div>
              {latestLabelConflict ? (
                <div className="rounded-md border border-border bg-surface-raised p-3">
                  <p className="text-sm text-text-secondary">
                    Selección guardada actual:{" "}
                    {latestLabelConflict.length > 0
                      ? latestLabelConflict
                          .map((label) => label.name)
                          .join(", ")
                      : "sin etiquetas"}
                    . Tu borrador sigue marcado en el selector.
                  </p>
                  <Button
                    type="button"
                    size="sm"
                    variant="ghost"
                    className="mt-2"
                    onClick={reviewLatestLabelConflict}
                  >
                    Revisar cambios actuales y conservar mi borrador
                  </Button>
                </div>
              ) : null}
              {labelsNotice ? (
                <output
                  className="block text-status-connected text-xs"
                  aria-live="polite"
                >
                  {labelsNotice}
                </output>
              ) : null}
            </section>
          ) : null}
          {showLabelCloseChoices ? (
            <section
              className="rounded-md border border-border bg-surface-raised p-4"
              aria-labelledby="birthday-label-close-heading"
            >
              <h3
                id="birthday-label-close-heading"
                className="font-semibold text-sm text-text-primary"
              >
                Hay etiquetas sin guardar
              </h3>
              <p className="mt-1 text-sm text-text-secondary">
                Puedes guardar o descartar el selector antes de continuar. Los
                datos del cumpleaños se guardan por separado.
              </p>
              <div className="mt-4 flex flex-col-reverse gap-2 sm:flex-row sm:flex-wrap sm:justify-end">
                <Button
                  type="button"
                  variant="primary"
                  onClick={() => void saveLabelsAndContinue()}
                  disabled={
                    !labelsDirty ||
                    labelsSaving ||
                    pending ||
                    latestLabelConflict !== null
                  }
                >
                  Guardar etiquetas y continuar
                </Button>
                <Button
                  type="button"
                  variant="danger"
                  onClick={discardLabelsAndContinue}
                  disabled={labelsSaving || pending}
                >
                  Descartar etiquetas y continuar
                </Button>
                <Button
                  type="button"
                  variant="ghost"
                  onClick={cancelLabelActionAndKeepEditing}
                  disabled={labelsSaving || pending}
                >
                  Seguir editando
                </Button>
              </div>
            </section>
          ) : null}
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
                onClick={requestBirthdayDelete}
                disabled={pending}
              >
                <IconTrash size={16} aria-hidden="true" />
                Eliminar
              </Button>
              <div className="flex justify-end gap-2">
                <Button
                  type="button"
                  variant="ghost"
                  onClick={requestEditorClose}
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
                onClick={requestEditorClose}
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
