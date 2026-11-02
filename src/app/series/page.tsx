import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { CopyOccurrenceLinkAction } from "@/components/series/copy-occurrence-link-action";
import { DeleteSeriesButton } from "@/components/series/delete-series-button";
import { HistoricalTaskCopyAction } from "@/components/series/historical-task-copy-action";
import { StopSeriesButton } from "@/components/series/stop-series-button";
import { Logo } from "@/components/ui/logo";
import { resolveApplicationAccess } from "@/lib/auth";
import { getFullBoard } from "@/lib/db/boards";
import {
  getRepetitionHistoryOccurrence,
  getRepetitionHistoryPage,
  listRepetitionSeries,
  previewHistoricalTaskCopy,
  type RepetitionHistoryOccurrence,
  type RepetitionOccurrenceDetail,
  type RepetitionSeriesListItem,
} from "@/lib/db/repetition-series";
import { repetitionPatternSummary } from "@/lib/repetition-pattern";
import {
  buildRepetitionOccurrenceHref,
  buildSeriesTaskEditorHref,
} from "@/lib/repetition-series-navigation";
import { createClient } from "@/lib/supabase/server";
import type { Board, Column, TaskComment } from "@/lib/types";

export const metadata: Metadata = {
  title: "Series e historial",
  description: "Consulta las series accesibles y sus ocurrencias históricas.",
  robots: { index: false, follow: false, nocache: true },
};

interface SeriesPageProps {
  searchParams: Promise<{
    board?: string | string[];
    state?: string | string[];
    series?: string | string[];
    occurrence?: string | string[];
    comment?: string | string[];
    series_before_created_at?: string | string[];
    series_before_id?: string | string[];
    history_before_on?: string | string[];
    history_before_id?: string | string[];
  }>;
}

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function one(value: string | string[] | undefined) {
  return typeof value === "string" ? value : undefined;
}

function validUuid(value: string | undefined) {
  return value && uuidPattern.test(value) ? value : null;
}

function formatDate(value: string | null | undefined) {
  if (!value) return "—";
  const date = new Date(`${value.slice(0, 10)}T00:00:00Z`);
  return new Intl.DateTimeFormat("es-AR", {
    dateStyle: "medium",
    timeZone: "UTC",
  }).format(date);
}

function occurrenceLabel(occurrence: RepetitionHistoryOccurrence) {
  const states: Record<RepetitionHistoryOccurrence["state"], string> = {
    current: "Vigente",
    replaced: "Reemplazada",
    excluded: "Excluida",
    purged: "Purgada",
    transferred: "Transferida a otra serie",
    retired: "Fuera de la serie",
  };
  return states[occurrence.state];
}

function frequencyLabel(frequency: RepetitionSeriesListItem["rule"]) {
  const labels = {
    daily: "Diaria",
    weekly: "Semanal",
    monthly: "Mensual",
    yearly: "Anual",
  };
  return labels[frequency];
}

function listHref(
  boardId: string | null,
  state: "active" | "stopped" | "finished" | null,
  cursor?: { created_at: string; id: string } | null,
) {
  const query = new URLSearchParams();
  if (boardId) query.set("board", boardId);
  if (state) query.set("state", state);
  if (cursor) {
    query.set("series_before_created_at", cursor.created_at);
    query.set("series_before_id", cursor.id);
  }
  return `/series${query.size ? `?${query}` : ""}`;
}

function historyHref(
  boardId: string,
  seriesId: string,
  state: "active" | "stopped" | "finished" | null,
  cursor?: { occurrence_on: string; id: string } | null,
) {
  const query = new URLSearchParams({ board: boardId, series: seriesId });
  if (state) query.set("state", state);
  if (cursor) {
    query.set("history_before_on", cursor.occurrence_on);
    query.set("history_before_id", cursor.id);
  }
  return `/series?${query}`;
}

function occurrenceHref(
  boardId: string,
  seriesId: string,
  occurrenceId: string,
  state: "active" | "stopped" | "finished" | null,
  cursor: { occurrence_on: string; id: string } | null,
) {
  const query = new URLSearchParams({
    board: boardId,
    series: seriesId,
    occurrence: occurrenceId,
  });
  if (state) query.set("state", state);
  if (cursor) {
    query.set("history_before_on", cursor.occurrence_on);
    query.set("history_before_id", cursor.id);
  }
  return `/series?${query}`;
}

function safePageError() {
  return "No se pudo cargar esta parte del historial. Actualiza la página para volver a consultar el acceso actual.";
}

export default async function SeriesPage({ searchParams }: SeriesPageProps) {
  const query = await searchParams;
  const selectedBoardId = validUuid(one(query.board));
  const requestedState = one(query.state);
  const selectedState =
    requestedState === "active" ||
    requestedState === "stopped" ||
    requestedState === "finished"
      ? requestedState
      : null;
  const selectedSeriesId = validUuid(one(query.series));
  const selectedOccurrenceId = validUuid(one(query.occurrence));
  const selectedCommentId = validUuid(one(query.comment));
  const listCursorCreatedAt = one(query.series_before_created_at) ?? null;
  const listCursorId = validUuid(one(query.series_before_id));
  const historyCursorOn = one(query.history_before_on) ?? null;
  const historyCursorId = validUuid(one(query.history_before_id));
  const listCursor =
    listCursorCreatedAt && listCursorId
      ? { created_at: listCursorCreatedAt, id: listCursorId }
      : null;
  const historyCursor =
    historyCursorOn && historyCursorId
      ? { occurrence_on: historyCursorOn, id: historyCursorId }
      : null;

  const supabase = await createClient();
  const { data: authData } = await supabase.auth.getUser();
  if (!authData.user) {
    const returnQuery = new URLSearchParams();
    if (selectedBoardId) returnQuery.set("board", selectedBoardId);
    if (selectedState) returnQuery.set("state", selectedState);
    if (selectedSeriesId) returnQuery.set("series", selectedSeriesId);
    if (selectedOccurrenceId)
      returnQuery.set("occurrence", selectedOccurrenceId);
    if (selectedCommentId) returnQuery.set("comment", selectedCommentId);
    const returnPath = `/series${returnQuery.size ? `?${returnQuery}` : ""}`;
    redirect(`/login?next=${encodeURIComponent(returnPath)}`);
  }
  const access = await resolveApplicationAccess(supabase);
  if (access.status !== "active") redirect("/");

  let boards: Board[] = [];
  try {
    const { data } = await supabase.rpc("list_my_boards");
    boards = (data ?? []) as Board[];
  } catch {
    boards = [];
  }

  let series: RepetitionSeriesListItem[] = [];
  let seriesCursor: { created_at: string; id: string } | null = null;
  let seriesHasMore = false;
  let seriesLoadError = false;
  try {
    const page = await listRepetitionSeries(
      supabase,
      selectedBoardId,
      selectedState,
      listCursor,
      20,
    );
    if (page.status === "available") {
      series = page.series;
      seriesCursor = page.next_cursor ?? null;
      seriesHasMore = page.has_more;
    }
  } catch {
    seriesLoadError = true;
  }

  let history: Awaited<ReturnType<typeof getRepetitionHistoryPage>> | null =
    null;
  let historyLoadError = false;
  if (selectedSeriesId) {
    try {
      history = await getRepetitionHistoryPage(
        supabase,
        selectedSeriesId,
        historyCursor,
        30,
      );
      if (history.status !== "available") history = null;
    } catch {
      historyLoadError = true;
    }
  }

  let occurrenceDetail: RepetitionOccurrenceDetail | null = null;
  let occurrenceLoadError = false;
  if (selectedSeriesId && selectedOccurrenceId && history) {
    try {
      occurrenceDetail = await getRepetitionHistoryOccurrence(
        supabase,
        selectedSeriesId,
        selectedOccurrenceId,
      );
      if (occurrenceDetail.status !== "available") occurrenceDetail = null;
    } catch {
      occurrenceLoadError = true;
    }
  }

  let historyComments: TaskComment[] = [];
  let commentLoadError = false;
  const detailTask = occurrenceDetail?.occurrence?.task;
  const boardSlug = occurrenceDetail?.board_slug;
  if (detailTask && boardSlug) {
    try {
      const { data, error } = await supabase.rpc("get_task_comments_p", {
        p_slug: boardSlug,
        p_task_id: detailTask.id,
        p_limit: 30,
        p_before_created_at: null,
        p_before_id: null,
        p_anchor_comment_id: selectedCommentId,
      });
      if (error) throw error;
      if (
        typeof data === "object" &&
        data !== null &&
        "status" in data &&
        data.status === "available" &&
        "comments" in data &&
        Array.isArray(data.comments)
      ) {
        historyComments = data.comments as TaskComment[];
      }
    } catch {
      commentLoadError = true;
    }
  }

  let columns: Pick<Column, "id" | "title">[] = [];
  let copyPreview = null;
  if (
    detailTask &&
    boardSlug &&
    occurrenceDetail?.occurrence?.content_available
  ) {
    try {
      const boardData = await getFullBoard(supabase, boardSlug);
      columns = (boardData?.columns ?? []).map(({ id, title }) => ({
        id,
        title,
      }));
      copyPreview = await previewHistoricalTaskCopy(
        supabase,
        boardSlug,
        detailTask.id,
      );
    } catch {
      columns = [];
      copyPreview = null;
    }
  }

  const selectedHistorySeries = history?.series;
  const selectedOccurrence = occurrenceDetail?.occurrence;
  const selectedCommentForLink =
    selectedCommentId &&
    historyComments.some((comment) => comment.id === selectedCommentId)
      ? selectedCommentId
      : null;
  const selectedOccurrenceHref =
    selectedHistorySeries && selectedOccurrence
      ? buildRepetitionOccurrenceHref({
          boardId: selectedHistorySeries.board_id,
          seriesId: selectedHistorySeries.id,
          occurrenceId: selectedOccurrence.id,
          commentId: selectedCommentForLink,
        })
      : null;
  const currentOccurrence = history?.occurrences.find(
    (occurrence) => occurrence.state === "current" && occurrence.task_id,
  );

  return (
    <main className="mx-auto min-h-dvh max-w-7xl bg-surface-base px-5 py-8 text-text-primary sm:px-8">
      <header className="flex flex-wrap items-center justify-between gap-4 border-border border-b pb-6">
        <Logo />
        <nav
          aria-label="Navegación principal"
          className="flex flex-wrap items-center gap-3"
        >
          <Link
            href="/"
            className="rounded-lg border border-border px-4 py-2 text-sm text-text-secondary transition hover:bg-surface-hover hover:text-text-primary"
          >
            Tus tableros
          </Link>
          <Link
            href="/my-tasks?order=due"
            className="rounded-lg border border-border px-4 py-2 text-sm text-text-secondary transition hover:bg-surface-hover hover:text-text-primary"
          >
            Mis tareas
          </Link>
        </nav>
      </header>

      <section className="mt-10">
        <p className="text-sm text-text-secondary">
          Consulta independiente de las tarjetas visibles
        </p>
        <h1 className="mt-1 font-bold font-display text-4xl tracking-tight">
          Series e historial
        </h1>
      </section>

      <form
        action="/series"
        method="get"
        className="mt-7 flex flex-wrap items-end gap-3"
      >
        <div className="flex min-w-56 flex-col gap-1.5">
          <label
            htmlFor="series-board-filter"
            className="font-medium text-text-secondary text-xs"
          >
            Filtrar por tablero
          </label>
          <select
            id="series-board-filter"
            name="board"
            defaultValue={selectedBoardId ?? "all"}
            className="h-11 rounded-md border border-border bg-surface-raised px-3 text-sm text-text-primary outline-none focus:border-accent"
          >
            <option value="all">Todos los tableros</option>
            {boards.map((board) => (
              <option key={board.id} value={board.id}>
                {board.name}
              </option>
            ))}
          </select>
        </div>
        <div className="flex min-w-48 flex-col gap-1.5">
          <label
            htmlFor="series-state-filter"
            className="font-medium text-text-secondary text-xs"
          >
            Filtrar por estado
          </label>
          <select
            id="series-state-filter"
            name="state"
            defaultValue={selectedState ?? "all"}
            className="h-11 rounded-md border border-border bg-surface-raised px-3 text-sm text-text-primary outline-none focus:border-accent"
          >
            <option value="all">Todos los estados</option>
            <option value="active">Activas</option>
            <option value="stopped">Detenidas</option>
            <option value="finished">Finalizadas</option>
          </select>
        </div>
        <button
          type="submit"
          className="h-11 rounded-md border border-border px-4 text-sm text-text-secondary transition hover:bg-surface-hover hover:text-text-primary"
        >
          Aplicar filtro
        </button>
      </form>

      <div className="mt-8 grid gap-8 lg:grid-cols-[minmax(16rem,0.75fr)_minmax(0,1.5fr)]">
        <aside
          aria-label="Series accesibles"
          className="rounded-2xl border border-border bg-surface-raised p-4 sm:p-5"
        >
          <h2 className="font-semibold text-lg">Series accesibles</h2>
          {seriesLoadError ? (
            <p className="mt-4 text-priority-urgent text-sm" role="alert">
              {safePageError()}
            </p>
          ) : series.length === 0 ? (
            <p className="mt-4 text-sm text-text-secondary">
              No hay series para este filtro. Las tarjetas completadas o fuera
              del tablero visible no ocultan sus series.
            </p>
          ) : (
            <ul className="mt-4 flex flex-col gap-2">
              {series.map((entry) => {
                const entryQuery = new URLSearchParams({
                  board: entry.board_id,
                  series: entry.id,
                });
                if (selectedState) entryQuery.set("state", selectedState);
                const href = `/series?${entryQuery}`;
                const isSelected = entry.id === selectedSeriesId;
                const appearanceOn = entry.next_appearance_on ?? null;
                const dueOn =
                  entry.next_due_on && entry.next_due_on !== appearanceOn
                    ? entry.next_due_on
                    : null;
                const editorHref =
                  entry.state === "active" && entry.current_task_id
                    ? buildSeriesTaskEditorHref({
                        boardSlug: entry.board_slug,
                        taskId: entry.current_task_id,
                        boardId: selectedBoardId,
                        state: selectedState,
                        listCursor,
                        selectedSeriesId,
                        selectedOccurrenceId,
                        selectedCommentId,
                        historyCursor,
                      })
                    : null;
                return (
                  <li
                    key={entry.id}
                    className={`rounded-xl border p-3 transition ${isSelected ? "border-accent bg-surface-overlay" : "border-border hover:bg-surface-hover"}`}
                  >
                    <Link
                      href={href}
                      aria-current={isSelected ? "page" : undefined}
                      className="block rounded-md focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
                    >
                      <span className="block break-words font-medium text-sm text-text-primary">
                        {entry.current_task_title ||
                          `Serie iniciada el ${formatDate(entry.start_on)}`}
                      </span>
                      <span className="mt-1 block text-text-secondary text-xs">
                        {entry.board_name} ·{" "}
                        {entry.state === "active"
                          ? "Activa"
                          : entry.state === "stopped"
                            ? "Detenida"
                            : "Finalizada"}
                      </span>
                      <span className="mt-1 block text-text-secondary text-xs">
                        {repetitionPatternSummary(entry.pattern) ??
                          frequencyLabel(entry.rule)}
                      </span>
                      <span className="mt-1 block text-text-muted text-xs">
                        {appearanceOn
                          ? `Aparece el ${formatDate(appearanceOn)}`
                          : "Sin próxima aparición"}
                        {dueOn ? ` · Vence el ${formatDate(dueOn)}` : ""}
                      </span>
                    </Link>
                    {editorHref ? (
                      <Link
                        href={editorHref}
                        className="mt-2 inline-flex rounded-md px-1 py-1 text-accent text-xs hover:underline focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
                      >
                        Editar próximas repeticiones
                      </Link>
                    ) : null}
                  </li>
                );
              })}
            </ul>
          )}
          {seriesHasMore && seriesCursor ? (
            <Link
              href={listHref(selectedBoardId, selectedState, seriesCursor)}
              className="mt-4 inline-flex rounded-md px-2 py-2 text-accent text-sm hover:underline"
            >
              Cargar más series
            </Link>
          ) : null}
        </aside>

        <section className="min-w-0 rounded-2xl border border-border bg-surface-raised p-4 sm:p-6">
          {!selectedSeriesId ? (
            <div>
              <h2 className="font-semibold text-xl">Elige una serie</h2>
              <p className="mt-2 text-sm text-text-secondary leading-6">
                El historial se consulta por páginas. Abrir una ocurrencia
                muestra su fecha, estado y contenido disponible sin convertirla
                en pendiente ni modificarla.
              </p>
            </div>
          ) : historyLoadError ? (
            <p className="text-priority-urgent text-sm" role="alert">
              {safePageError()}
            </p>
          ) : !history || !selectedHistorySeries ? (
            <p className="text-sm text-text-secondary">
              La serie no está disponible con tu acceso actual.
            </p>
          ) : (
            <>
              <div className="flex flex-wrap items-start justify-between gap-4 border-border border-b pb-5">
                <div>
                  <p className="text-sm text-text-secondary">
                    {selectedHistorySeries.board_name}
                  </p>
                  <h2 className="mt-1 font-semibold text-2xl">
                    Historial de la serie
                  </h2>
                  <p className="mt-2 text-sm text-text-secondary">
                    {frequencyLabel(selectedHistorySeries.rule)} ·{" "}
                    {selectedHistorySeries.state === "active"
                      ? "Activa"
                      : selectedHistorySeries.state === "stopped"
                        ? "Detenida"
                        : "Finalizada"}{" "}
                    · {selectedHistorySeries.consumed_count} ocurrencias
                  </p>
                </div>
                <div className="flex flex-col items-start gap-3">
                  {selectedHistorySeries.state === "active" ? (
                    <StopSeriesButton
                      slug={selectedHistorySeries.board_slug}
                      seriesId={selectedHistorySeries.id}
                      revision={selectedHistorySeries.revision}
                    />
                  ) : null}
                  <DeleteSeriesButton
                    slug={selectedHistorySeries.board_slug}
                    boardId={selectedHistorySeries.board_id}
                    seriesId={selectedHistorySeries.id}
                    returnState={selectedState}
                  />
                </div>
              </div>

              {selectedHistorySeries.state === "stopped" &&
              currentOccurrence?.task_id ? (
                <Link
                  href={`/${selectedHistorySeries.board_slug}?task=${currentOccurrence.task_id}`}
                  className="mt-4 inline-flex rounded-md px-2 py-2 text-accent text-sm hover:underline"
                >
                  Abrir la tarjeta vigente para programar una serie nueva
                </Link>
              ) : null}

              <div className="mt-5 grid gap-6 xl:grid-cols-[minmax(14rem,0.75fr)_minmax(0,1.25fr)]">
                <section aria-label="Ocurrencias de la serie">
                  <h3 className="font-semibold text-base">Ocurrencias</h3>
                  {history.occurrences.length === 0 ? (
                    <p className="mt-3 text-sm text-text-secondary">
                      Todavía no hay ocurrencias para mostrar.
                    </p>
                  ) : (
                    <ol className="mt-3 flex flex-col gap-2">
                      {history.occurrences.map((occurrence) => {
                        const href = occurrenceHref(
                          selectedHistorySeries.board_id,
                          selectedHistorySeries.id,
                          occurrence.id,
                          selectedState,
                          historyCursor,
                        );
                        const selected = occurrence.id === selectedOccurrenceId;
                        return (
                          <li key={occurrence.id}>
                            <Link
                              href={`${href}#occurrence-detail`}
                              aria-current={selected ? "page" : undefined}
                              className={`block rounded-lg border p-3 ${selected ? "border-accent bg-surface-overlay" : "border-border hover:bg-surface-hover"}`}
                            >
                              <span className="block font-medium text-sm text-text-primary">
                                {formatDate(occurrence.occurrence_on)} ·{" "}
                                {occurrenceLabel(occurrence)}
                              </span>
                              <span className="mt-1 block truncate text-text-secondary text-xs">
                                {occurrence.content_available
                                  ? occurrence.title
                                  : "Contenido no disponible"}
                              </span>
                            </Link>
                          </li>
                        );
                      })}
                    </ol>
                  )}
                  {history.has_more && history.next_cursor ? (
                    <Link
                      href={historyHref(
                        selectedHistorySeries.board_id,
                        selectedHistorySeries.id,
                        selectedState,
                        history.next_cursor,
                      )}
                      className="mt-3 inline-flex rounded-md px-2 py-2 text-accent text-sm hover:underline"
                    >
                      Cargar más ocurrencias
                    </Link>
                  ) : null}
                </section>

                <section
                  id="occurrence-detail"
                  aria-label="Detalle de ocurrencia"
                  className="min-w-0 rounded-xl border border-border p-4"
                >
                  {occurrenceLoadError ? (
                    <p className="text-priority-urgent text-sm" role="alert">
                      {safePageError()}
                    </p>
                  ) : !selectedOccurrenceId ? (
                    <p className="text-sm text-text-secondary">
                      Elige una ocurrencia para abrir su detalle preciso.
                    </p>
                  ) : !occurrenceDetail || !selectedOccurrence ? (
                    <p className="text-sm text-text-secondary">
                      La ocurrencia no está disponible con tu acceso actual.
                    </p>
                  ) : (
                    <>
                      <p className="text-sm text-text-secondary">
                        {formatDate(selectedOccurrence.occurrence_on)} ·{" "}
                        {occurrenceLabel(selectedOccurrence)}
                      </p>
                      {selectedOccurrenceHref ? (
                        <CopyOccurrenceLinkAction
                          href={selectedOccurrenceHref}
                        />
                      ) : null}
                      {selectedOccurrence.content_available &&
                      selectedOccurrence.task ? (
                        <>
                          <h3 className="mt-1 break-words font-semibold text-xl">
                            {selectedOccurrence.task.title}
                          </h3>
                          {selectedOccurrence.task.description ? (
                            <p className="mt-3 whitespace-pre-wrap break-words text-sm text-text-secondary leading-6">
                              {selectedOccurrence.task.description}
                            </p>
                          ) : null}
                          <dl className="mt-4 grid grid-cols-2 gap-3 text-sm">
                            <div>
                              <dt className="text-text-muted text-xs">
                                Prioridad
                              </dt>
                              <dd className="mt-1 text-text-primary">
                                {selectedOccurrence.task.priority}
                              </dd>
                            </div>
                            <div>
                              <dt className="text-text-muted text-xs">
                                Estado de tarea
                              </dt>
                              <dd className="mt-1 text-text-primary">
                                {selectedOccurrence.task.is_completed
                                  ? "Completada"
                                  : "Pendiente"}
                              </dd>
                            </div>
                            <div>
                              <dt className="text-text-muted text-xs">
                                Vencimiento
                              </dt>
                              <dd className="mt-1 text-text-primary">
                                {formatDate(selectedOccurrence.task.due_on)}
                              </dd>
                            </div>
                            <div>
                              <dt className="text-text-muted text-xs">
                                Comentarios
                              </dt>
                              <dd className="mt-1 text-text-primary">
                                {selectedOccurrence.task.comment_count}
                              </dd>
                            </div>
                          </dl>
                          {selectedOccurrence.task.latest_comment_id ? (
                            <Link
                              href={`${occurrenceHref(selectedHistorySeries.board_id, selectedHistorySeries.id, selectedOccurrence.id, selectedState, historyCursor)}&comment=${selectedOccurrence.task.latest_comment_id}#comment-${selectedOccurrence.task.latest_comment_id}`}
                              className="mt-4 inline-flex rounded-md px-2 py-2 text-accent text-sm hover:underline"
                            >
                              Abrir el comentario más reciente
                            </Link>
                          ) : null}
                          <section
                            aria-label="Conversación autorizada"
                            className="mt-5 border-border border-t pt-4"
                          >
                            <h4 className="font-semibold text-base">
                              Conversación
                            </h4>
                            {commentLoadError ? (
                              <p
                                className="mt-2 text-sm text-text-secondary"
                                role="alert"
                              >
                                No se pudo cargar la conversación con el acceso
                                actual.
                              </p>
                            ) : historyComments.length ? (
                              <ol className="mt-3 flex flex-col gap-3">
                                {historyComments.map((comment) => (
                                  <li key={comment.id}>
                                    <article
                                      id={`comment-${comment.id}`}
                                      aria-label={
                                        comment.id === selectedCommentId
                                          ? "Comentario seleccionado"
                                          : undefined
                                      }
                                      className={`rounded-lg border p-3 ${comment.id === selectedCommentId ? "border-accent bg-surface-overlay" : "border-border"}`}
                                    >
                                      <p className="text-text-muted text-xs">
                                        {comment.author_name || "Colaborador"} ·{" "}
                                        {formatDate(comment.created_at)}
                                      </p>
                                      <p className="mt-2 whitespace-pre-wrap break-words text-sm text-text-primary">
                                        {comment.deleted
                                          ? "Este comentario fue eliminado."
                                          : (comment.content ??
                                            "Este comentario ya no tiene contenido disponible.")}
                                      </p>
                                      <Link
                                        href={`${occurrenceHref(selectedHistorySeries.board_id, selectedHistorySeries.id, selectedOccurrence.id, selectedState, historyCursor)}&comment=${comment.id}#comment-${comment.id}`}
                                        className="mt-2 inline-flex rounded-md px-1 py-1 text-accent text-xs hover:underline"
                                      >
                                        Abrir este comentario
                                      </Link>
                                    </article>
                                  </li>
                                ))}
                              </ol>
                            ) : (
                              <p className="mt-2 text-sm text-text-secondary">
                                No hay comentarios disponibles para esta
                                ocurrencia.
                              </p>
                            )}
                          </section>
                          {copyPreview ? (
                            <div className="mt-4 border-border border-t pt-4">
                              <HistoricalTaskCopyAction
                                slug={selectedHistorySeries.board_slug}
                                preview={copyPreview}
                                columns={columns}
                              />
                            </div>
                          ) : null}
                        </>
                      ) : (
                        <p className="mt-3 text-sm text-text-secondary leading-6">
                          El contenido original fue eliminado o purgado. Se
                          conserva la fecha y el estado de esta ocurrencia, sin
                          recuperar una copia de su texto.
                        </p>
                      )}
                    </>
                  )}
                </section>
              </div>
            </>
          )}
        </section>
      </div>
    </main>
  );
}
