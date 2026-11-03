export type RepetitionSeriesState = "active" | "stopped" | "finished";

export interface SeriesTaskEditorNavigation {
  boardSlug: string;
  taskId: string;
  boardId: string | null;
  state: RepetitionSeriesState | null;
  listCursor?: { created_at: string; id: string } | null;
  selectedSeriesId?: string | null;
  selectedOccurrenceId?: string | null;
  selectedCommentId?: string | null;
  historyCursor?: { occurrence_on: string; id: string } | null;
}

export interface SeriesTaskEditorIntentInput {
  taskId: string | null;
  editRepetition: string | null;
  from: string | null;
  seriesBoardId: string | null;
  seriesState: string | null;
  seriesBeforeCreatedAt: string | null;
  seriesBeforeId: string | null;
  selectedSeriesId: string | null;
  selectedOccurrenceId: string | null;
  selectedCommentId: string | null;
  historyBeforeOn: string | null;
  historyBeforeId: string | null;
  authorizedBoardTaskIds: readonly string[];
}

export interface SeriesTaskEditorIntent {
  taskId: string;
  returnHref: string | null;
}

export interface RepetitionOccurrenceLink {
  boardId: string;
  seriesId: string;
  occurrenceId: string;
  commentId?: string | null;
}

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const slugPattern = /^[a-z0-9-]{1,100}$/i;

export function buildRepetitionOccurrenceHref({
  boardId,
  seriesId,
  occurrenceId,
  commentId,
}: RepetitionOccurrenceLink): string | null {
  if (
    !uuidPattern.test(boardId) ||
    !uuidPattern.test(seriesId) ||
    !uuidPattern.test(occurrenceId) ||
    (commentId != null && !uuidPattern.test(commentId))
  ) {
    return null;
  }

  const query = new URLSearchParams({
    board: boardId,
    series: seriesId,
    occurrence: occurrenceId,
  });
  if (commentId) query.set("comment", commentId);
  return `/series?${query.toString()}${commentId ? `#comment-${commentId}` : ""}`;
}

function isSeriesState(value: string | null): value is RepetitionSeriesState {
  return value === "active" || value === "stopped" || value === "finished";
}

function validListCursor(
  createdAt: string | null,
  id: string | null,
): { created_at: string; id: string } | null {
  if (
    createdAt &&
    /^\d{4}-\d{2}-\d{2}T/.test(createdAt) &&
    Number.isFinite(Date.parse(createdAt)) &&
    id &&
    uuidPattern.test(id)
  ) {
    return { created_at: createdAt, id };
  }
  return null;
}

function validHistoryCursor(
  occurrenceOn: string | null,
  id: string | null,
): { occurrence_on: string; id: string } | null {
  if (
    occurrenceOn &&
    /^\d{4}-\d{2}-\d{2}$/.test(occurrenceOn) &&
    id &&
    uuidPattern.test(id)
  ) {
    return { occurrence_on: occurrenceOn, id };
  }
  return null;
}

function seriesListHref(
  boardId: string | null,
  state: RepetitionSeriesState | null,
  listCursor?: { created_at: string; id: string } | null,
  selectedSeriesId?: string | null,
  selectedOccurrenceId?: string | null,
  selectedCommentId?: string | null,
  historyCursor?: { occurrence_on: string; id: string } | null,
) {
  const query = new URLSearchParams();
  if (boardId && uuidPattern.test(boardId)) query.set("board", boardId);
  if (state) query.set("state", state);
  if (selectedSeriesId && uuidPattern.test(selectedSeriesId)) {
    query.set("series", selectedSeriesId);
  }
  if (selectedOccurrenceId && uuidPattern.test(selectedOccurrenceId)) {
    query.set("occurrence", selectedOccurrenceId);
  }
  if (selectedCommentId && uuidPattern.test(selectedCommentId)) {
    query.set("comment", selectedCommentId);
  }
  if (listCursor && validListCursor(listCursor.created_at, listCursor.id)) {
    query.set("series_before_created_at", listCursor.created_at);
    query.set("series_before_id", listCursor.id);
  }
  if (
    historyCursor &&
    validHistoryCursor(historyCursor.occurrence_on, historyCursor.id)
  ) {
    query.set("history_before_on", historyCursor.occurrence_on);
    query.set("history_before_id", historyCursor.id);
  }
  return `/series${query.size ? `?${query.toString()}` : ""}`;
}

export function buildSeriesTaskEditorHref({
  boardSlug,
  taskId,
  boardId,
  state,
  listCursor,
  selectedSeriesId,
  selectedOccurrenceId,
  selectedCommentId,
  historyCursor,
}: SeriesTaskEditorNavigation) {
  if (
    !slugPattern.test(boardSlug) ||
    !uuidPattern.test(taskId) ||
    (boardId !== null && !uuidPattern.test(boardId))
  ) {
    return "/series";
  }

  const query = new URLSearchParams({
    task: taskId,
    edit_repetition: "1",
    from: "series",
  });
  if (boardId) query.set("series_board", boardId);
  if (state) query.set("series_state", state);
  if (selectedSeriesId && uuidPattern.test(selectedSeriesId)) {
    query.set("series_selected_id", selectedSeriesId);
  }
  if (selectedOccurrenceId && uuidPattern.test(selectedOccurrenceId)) {
    query.set("series_selected_occurrence", selectedOccurrenceId);
  }
  if (selectedCommentId && uuidPattern.test(selectedCommentId)) {
    query.set("series_selected_comment", selectedCommentId);
  }
  if (listCursor && validListCursor(listCursor.created_at, listCursor.id)) {
    query.set("series_before_created_at", listCursor.created_at);
    query.set("series_before_id", listCursor.id);
  }
  if (
    historyCursor &&
    validHistoryCursor(historyCursor.occurrence_on, historyCursor.id)
  ) {
    query.set("series_history_before_on", historyCursor.occurrence_on);
    query.set("series_history_before_id", historyCursor.id);
  }
  return `/${boardSlug}?${query.toString()}`;
}

export function resolveSeriesTaskEditorIntent({
  taskId,
  editRepetition,
  from,
  seriesBoardId,
  seriesState,
  seriesBeforeCreatedAt,
  seriesBeforeId,
  selectedSeriesId,
  selectedOccurrenceId,
  selectedCommentId,
  historyBeforeOn,
  historyBeforeId,
  authorizedBoardTaskIds,
}: SeriesTaskEditorIntentInput): SeriesTaskEditorIntent | null {
  if (
    editRepetition !== "1" ||
    !taskId ||
    !uuidPattern.test(taskId) ||
    !authorizedBoardTaskIds.includes(taskId)
  ) {
    return null;
  }

  return {
    taskId,
    returnHref:
      from === "series"
        ? seriesListHref(
            seriesBoardId,
            isSeriesState(seriesState) ? seriesState : null,
            validListCursor(seriesBeforeCreatedAt, seriesBeforeId),
            selectedSeriesId,
            selectedOccurrenceId,
            selectedCommentId,
            validHistoryCursor(historyBeforeOn, historyBeforeId),
          )
        : null,
  };
}
