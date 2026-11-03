"use client";

import type { AuthChangeEvent, Session } from "@supabase/supabase-js";
import { IconHistory, IconSearch, IconX } from "@tabler/icons-react";
import Link from "next/link";
import { useEffect, useMemo, useRef, useState } from "react";
import { ViewPreferenceStatus } from "@/components/preferences/view-preference-status";
import { SavedViewsPanel } from "@/components/saved-views/saved-views-panel";
import { useViewPreferences } from "@/hooks/use-view-preferences";
import type { UnifiedSearchResult } from "@/lib/db/unified-search";
import type {
  SavedViewDefinition,
  SavedViewReferenceField,
  SavedViewsSnapshot,
} from "@/lib/saved-view-state";
import { removeSavedViewCondition } from "@/lib/saved-view-state";
import { createClient } from "@/lib/supabase/client";
import { buildUnifiedSearchResultHref } from "@/lib/unified-search-navigation";
import type {
  UnifiedSearchMode,
  UnifiedSearchScope,
} from "@/lib/unified-search-request";
import {
  clearUnifiedSearchFilters,
  isCurrentUnifiedSearchRequest,
  postUnifiedSearch,
} from "@/lib/unified-search-state";
import type {
  ViewPreferenceContext,
  ViewPreferenceDrafts,
  ViewPreferenceSnapshot,
} from "@/lib/view-preference-state";

interface SearchBoardOption {
  id: string;
  slug: string;
  name: string;
}

interface SearchAssigneeOption {
  user_id: string;
  name: string;
  board_name: string;
}

interface SearchLabelFilter {
  board_id: string;
  label_id: string;
  label_name: string | null;
  board_name: string | null;
}

interface SearchUiState {
  query: string;
  scope: UnifiedSearchScope;
  boardSlug: string | null;
  filterBoardId: string | null;
  includeCompleted: boolean;
  includeHistory: boolean;
  priority: "low" | "medium" | "high" | "urgent" | null;
  assigneeId: string | null;
  unassigned: boolean;
  dueFilter: "today" | "overdue" | "next_7_days" | "no_date" | null;
  labelFilters: SearchLabelFilter[];
  order: "due" | "created";
  mode: UnifiedSearchMode;
}

interface SearchResponse {
  status:
    | "available"
    | "scope_unavailable"
    | "unavailable"
    | "invalid_filter"
    | "stale_page";
  results: UnifiedSearchResult[];
  has_more: boolean;
  next_cursor: Record<string, unknown> | null;
}

interface PendingSavedViewReview {
  definition: SavedViewDefinition;
  invalidReferences: SavedViewReferenceField[];
  boardScopeNeedsReplacement: boolean;
}

interface UnifiedSearchClientProps {
  accountId: string;
  boards: SearchBoardOption[];
  assignees: SearchAssigneeOption[];
  initialState: SearchUiState;
  preferenceContext: ViewPreferenceContext;
  initialViewPreferences: ViewPreferenceSnapshot | null;
  initialSavedViews: SavedViewsSnapshot;
  initialViewPreferencesLoadFailed: boolean;
  initialPreferenceDrafts?: ViewPreferenceDrafts;
  initialScopeUnavailable: boolean;
}

const groupLabels = {
  task: "Tareas",
  comment: "Comentarios",
  board: "Tableros",
  label: "Etiquetas para filtrar",
} as const;

function unavailableReferenceActionLabel(
  field: SavedViewReferenceField,
): string | null {
  switch (field) {
    case "filterBoardId":
      return "Quitar el filtro de tablero de esta vista";
    case "assigneeId":
      return "Quitar el filtro de responsable de esta vista";
    case "labels":
      return "Quitar todos los filtros de etiquetas de esta vista";
    case "boardId":
      return null;
  }
}

function toSearchParams(state: SearchUiState): URLSearchParams {
  const params = new URLSearchParams();
  params.set("view_state", "1");
  params.set("scope", state.scope);
  if (state.scope === "board" && state.boardSlug) {
    params.set("board_slug", state.boardSlug);
  }
  if (state.query) params.set("q", state.query);
  if (state.filterBoardId) params.set("filter_board_id", state.filterBoardId);
  if (state.includeCompleted) params.set("completed", "1");
  if (state.includeHistory) params.set("history", "1");
  if (state.priority) params.set("priority", state.priority);
  if (state.assigneeId) params.set("assignee", state.assigneeId);
  if (state.unassigned) params.set("unassigned", "1");
  if (state.dueFilter) params.set("due", state.dueFilter);
  for (const filter of state.labelFilters) {
    params.append("label", `${filter.board_id}:${filter.label_id}`);
  }
  if (state.order !== "due") params.set("order", state.order);
  if (state.mode !== "suggestions") params.set("mode", state.mode);
  return params;
}

function resultTitle(result: UnifiedSearchResult): string {
  if (result.kind === "board") return String(result.board_name);
  if (result.kind === "label") return String(result.label_name);
  if (result.kind === "comment") return String(result.task_title);
  return String(result.title);
}

function resultFieldLabel(result: UnifiedSearchResult): string {
  if (result.is_historical === true) return "Ocurrencia reemplazada";
  if (result.kind === "comment") return "Comentario";
  if (result.kind === "board") return "Tablero";
  if (result.kind === "label") return "Etiqueta";
  if (result.field === "comment") return "Comentario coincidente";
  return result.field === "description" ? "Descripción" : "Título";
}

function resultOrigin(result: UnifiedSearchResult): string {
  if (result.is_historical === true) {
    const day =
      typeof result.occurrence_on === "string"
        ? result.occurrence_on
        : "fecha de historial";
    return `Serie ${String(result.series_id).slice(0, 8)} · ${day}`;
  }
  if (result.kind === "comment") return `Tarea · ${String(result.board_name)}`;
  if (result.kind === "task") {
    return `${String(result.board_name)} · ${String(result.column_title)}`;
  }
  return "OpenKanban";
}

function backHref(state: SearchUiState): string {
  if (state.scope === "my_tasks") {
    return "/my-tasks";
  }
  if (state.scope === "board" && state.boardSlug) {
    return `/${encodeURIComponent(state.boardSlug)}`;
  }
  return "/";
}

export function UnifiedSearchClient({
  accountId,
  boards,
  assignees,
  initialState,
  preferenceContext,
  initialViewPreferences,
  initialSavedViews,
  initialViewPreferencesLoadFailed,
  initialPreferenceDrafts,
  initialScopeUnavailable,
}: UnifiedSearchClientProps) {
  const [navigationState, setNavigationState] = useState(() => ({
    query: initialState.query,
    scope: initialState.scope,
    boardSlug: initialState.boardSlug,
    mode: initialState.mode,
  }));
  const viewPreferences = useViewPreferences({
    accountId,
    context: preferenceContext,
    initialSnapshot: initialViewPreferences,
    initialDrafts: initialPreferenceDrafts,
    initialLoadFailed: initialViewPreferencesLoadFailed,
  });
  const values = viewPreferences.state.values;
  const savedResponsibility = values.filter_responsibility as
    | { assignee_id: string | null; unassigned: boolean }
    | undefined;
  const savedLabels = useMemo(
    () =>
      Array.isArray(values.filter_labels)
        ? values.filter_labels.filter(
            (entry): entry is { board_id: string; label_id: string } =>
              typeof entry === "object" &&
              entry !== null &&
              "board_id" in entry &&
              "label_id" in entry,
          )
        : [],
    [values.filter_labels],
  );
  const [labelNames, setLabelNames] = useState(
    () =>
      new Map(
        initialState.labelFilters.map((filter) => [
          `${filter.board_id}:${filter.label_id}`,
          filter,
        ]),
      ),
  );
  const state: SearchUiState = useMemo(
    () => ({
      ...navigationState,
      filterBoardId:
        typeof values.filter_board === "string" ? values.filter_board : null,
      includeCompleted: values.include_completed === true,
      includeHistory: values.include_history === true,
      priority:
        values.filter_priority === "low" ||
        values.filter_priority === "medium" ||
        values.filter_priority === "high" ||
        values.filter_priority === "urgent"
          ? values.filter_priority
          : null,
      assigneeId: savedResponsibility?.assignee_id ?? null,
      unassigned: savedResponsibility?.unassigned ?? false,
      dueFilter:
        values.filter_due === "today" ||
        values.filter_due === "overdue" ||
        values.filter_due === "next_7_days" ||
        values.filter_due === "no_date"
          ? values.filter_due
          : null,
      labelFilters: savedLabels.map((filter) => {
        const label = labelNames.get(`${filter.board_id}:${filter.label_id}`);
        return {
          ...filter,
          label_name: label?.label_name ?? null,
          board_name:
            label?.board_name ??
            boards.find((board) => board.id === filter.board_id)?.name ??
            null,
        };
      }),
      order: values.order === "created" ? "created" : "due",
    }),
    [
      boards,
      labelNames,
      navigationState,
      savedLabels,
      savedResponsibility,
      values,
    ],
  );
  const [results, setResults] = useState<UnifiedSearchResult[]>([]);
  const [loading, setLoading] = useState(false);
  const [hasMore, setHasMore] = useState(false);
  const [nextCursor, setNextCursor] = useState<Record<string, unknown> | null>(
    null,
  );
  const [refreshNonce, setRefreshNonce] = useState(0);
  const [pageCursor, setPageCursor] = useState<Record<string, unknown> | null>(
    null,
  );
  const [message, setMessage] = useState("");
  const [pendingSavedViewReview, setPendingSavedViewReview] =
    useState<PendingSavedViewReview | null>(null);
  const [accessUnavailable, setAccessUnavailable] = useState(false);
  const [scopeUnavailable, setScopeUnavailable] = useState(
    initialScopeUnavailable,
  );
  const requestId = useRef(0);
  const stalePageRestartRef = useRef(false);
  const accountIdRef = useRef(accountId);
  accountIdRef.current = accountId;
  const queryInputRef = useRef<HTMLInputElement>(null);

  const selectedBoard = boards.find((board) => board.slug === state.boardSlug);
  const currentSavedViewDefinition: SavedViewDefinition = {
    query: state.query,
    scope: state.scope,
    boardId: state.scope === "board" ? (selectedBoard?.id ?? null) : null,
    includeCompleted: state.includeCompleted,
    includeHistory: state.includeHistory,
    filterBoardId: state.filterBoardId,
    dueFilter: state.dueFilter,
    priority: state.priority,
    assigneeId: state.assigneeId,
    unassigned: state.unassigned,
    labels: state.labelFilters.map(({ board_id, label_id }) => ({
      boardId: board_id,
      labelId: label_id,
    })),
    order: state.order,
  };
  const selectedFilters = useMemo(
    () =>
      new Set(
        state.labelFilters.map(
          (filter) => `${filter.board_id}:${filter.label_id}`,
        ),
      ),
    [state.labelFilters],
  );
  const isPreferenceSaving = (key: string) =>
    Boolean(viewPreferences.state.saving[key]);
  function isPreferenceBlocked(key: string): boolean {
    return Boolean(
      viewPreferences.state.saving[key] || viewPreferences.state.conflicts[key],
    );
  }
  function preferenceControlProps(key: string) {
    const disabled =
      Boolean(pendingSavedViewReview) || isPreferenceBlocked(key);
    return {
      disabled,
      "aria-busy": isPreferenceSaving(key),
      "aria-describedby": disabled
        ? "search-preference-control-status"
        : undefined,
    };
  }
  const hasSavingPreferences =
    Object.keys(viewPreferences.state.saving).length > 0;
  const hasPreferenceConflicts =
    Object.keys(viewPreferences.state.conflicts).length > 0;
  const preferenceControlStatusMessage =
    hasSavingPreferences && hasPreferenceConflicts
      ? "Hay preferencias guardándose y otras requieren revisión; los controles afectados están deshabilitados."
      : hasSavingPreferences
        ? "Guardando preferencias de búsqueda; los controles afectados están deshabilitados."
        : hasPreferenceConflicts
          ? "Revisa el conflicto de preferencias; los controles afectados están deshabilitados."
          : "";
  const clearPreferenceKeys = [
    "filter_board",
    "include_completed",
    "include_history",
    "filter_priority",
    "filter_responsibility",
    "filter_due",
    "filter_labels",
  ];
  const isClearBlocked = clearPreferenceKeys.some(isPreferenceBlocked);

  useEffect(() => {
    queryInputRef.current?.focus();
  }, []);

  useEffect(() => {
    if (scopeUnavailable) return;
    window.history.replaceState(
      null,
      "",
      `/search?${toSearchParams(state).toString()}`,
    );
  }, [scopeUnavailable, state]);

  useEffect(() => {
    const supabase = createClient();
    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange(
      (_event: AuthChangeEvent, session: Session | null) => {
        const nextAccountId = session?.user?.id ?? null;
        if (nextAccountId === accountIdRef.current) return;
        requestId.current += 1;
        setResults([]);
        setMessage("La cuenta cambió. Actualizando el acceso a la búsqueda…");
        if (nextAccountId) {
          window.location.reload();
        } else {
          window.location.assign("/login?next=%2Fsearch");
        }
      },
    );
    return () => {
      subscription.unsubscribe();
    };
  }, []);

  useEffect(() => {
    const revalidate = () => {
      if (document.visibilityState !== "visible" || !state.query.trim()) return;
      setResults([]);
      setPageCursor(null);
      setNextCursor(null);
      setHasMore(false);
      setRefreshNonce((current) => current + 1);
    };
    window.addEventListener("focus", revalidate);
    document.addEventListener("visibilitychange", revalidate);
    const interval = window.setInterval(revalidate, 30_000);
    return () => {
      window.removeEventListener("focus", revalidate);
      document.removeEventListener("visibilitychange", revalidate);
      window.clearInterval(interval);
    };
  }, [state.query]);

  useEffect(() => {
    if (!viewPreferences.state.accessLost) return;
    requestId.current += 1;
    setPendingSavedViewReview(null);
    setResults([]);
    setHasMore(false);
    setNextCursor(null);
    setPageCursor(null);
    if (viewPreferences.state.context.type === "search_board") {
      setScopeUnavailable(true);
    } else {
      setAccessUnavailable(true);
    }
  }, [viewPreferences.state.accessLost, viewPreferences.state.context.type]);

  useEffect(() => {
    // Keep explicit refreshes in the same monotonically increasing stale guard.
    requestId.current += refreshNonce + 1;
    const currentRequestId = requestId.current;
    const controller = new AbortController();
    const timer = window.setTimeout(async () => {
      if (
        accessUnavailable ||
        scopeUnavailable ||
        pendingSavedViewReview ||
        viewPreferences.isLoading
      ) {
        setLoading(false);
        return;
      }
      if (!state.query.trim()) {
        setResults([]);
        setHasMore(false);
        setNextCursor(null);
        setMessage("Escribe para buscar en tus tableros accesibles.");
        setLoading(false);
        return;
      }

      setLoading(true);
      setMessage("");
      try {
        const response = await postUnifiedSearch(
          fetch,
          {
            query: state.query,
            scope: state.scope,
            boardSlug: state.scope === "board" ? state.boardSlug : null,
            filterBoardId: state.filterBoardId,
            includeCompleted: state.includeCompleted,
            includeHistory: state.includeHistory,
            priority: state.priority,
            assigneeId: state.assigneeId,
            unassigned: state.unassigned,
            dueFilter: state.dueFilter,
            labelFilters: state.labelFilters.map(({ board_id, label_id }) => ({
              board_id,
              label_id,
            })),
            order: state.order,
            mode: state.mode,
            cursor: pageCursor,
          },
          controller.signal,
        );
        const data = (await response.json()) as SearchResponse;
        if (!response.ok && data.status !== "stale_page") {
          throw new Error("search-failed");
        }
        if (
          !isCurrentUnifiedSearchRequest(
            currentRequestId,
            requestId.current,
            accountIdRef.current,
            accountId,
          )
        ) {
          return;
        }
        if (data.status === "unavailable") {
          setPendingSavedViewReview(null);
          setResults([]);
          setHasMore(false);
          setNextCursor(null);
          setAccessUnavailable(true);
          setMessage("La búsqueda ya no está disponible con este acceso.");
          return;
        }
        if (data.status === "scope_unavailable") {
          setResults([]);
          setHasMore(false);
          setNextCursor(null);
          setScopeUnavailable(true);
          setMessage(
            "Este tablero ya no está disponible con tu acceso actual.",
          );
          return;
        }
        if (data.status === "invalid_filter") {
          setResults([]);
          setHasMore(false);
          setNextCursor(null);
          setMessage(
            "Una etiqueta seleccionada ya no está disponible. Quita ese filtro para continuar.",
          );
          return;
        }
        if (data.status === "stale_page") {
          setResults([]);
          setHasMore(false);
          setNextCursor(null);
          if (pageCursor) {
            stalePageRestartRef.current = true;
            setPageCursor(null);
          } else {
            setMessage(
              "Los resultados cambiaron. Vuelve a ejecutar la búsqueda.",
            );
          }
          return;
        }
        const restartedAfterEdit =
          pageCursor === null && stalePageRestartRef.current;
        if (restartedAfterEdit) stalePageRestartRef.current = false;
        setResults((current) =>
          pageCursor ? [...current, ...data.results] : data.results,
        );
        setHasMore(data.has_more);
        setNextCursor(data.next_cursor);
        setMessage(
          restartedAfterEdit
            ? "Los resultados cambiaron y la búsqueda se reinició desde la primera página."
            : data.results.length === 0 && !pageCursor
            ? "No hay coincidencias para esta búsqueda y estos filtros."
            : "",
        );
      } catch (error) {
        if (error instanceof DOMException && error.name === "AbortError")
          return;
        if (currentRequestId !== requestId.current) return;
        setMessage(
          "No se pudo buscar. Comprueba la conexión e inténtalo de nuevo.",
        );
      } finally {
        if (currentRequestId === requestId.current) setLoading(false);
      }
    }, 180);

    return () => {
      window.clearTimeout(timer);
      controller.abort();
    };
  }, [
    accessUnavailable,
    accountId,
    pageCursor,
    pendingSavedViewReview,
    refreshNonce,
    scopeUnavailable,
    state,
    viewPreferences.isLoading,
  ]);

  function updateState(patch: Partial<SearchUiState>) {
    stalePageRestartRef.current = false;
    setPageCursor(null);
    setHasMore(false);
    setNextCursor(null);
    setResults([]);
    if ("filterBoardId" in patch) {
      viewPreferences.changePreference(
        "filter_board",
        patch.filterBoardId ?? null,
      );
    }
    if ("includeCompleted" in patch) {
      viewPreferences.changePreference(
        "include_completed",
        Boolean(patch.includeCompleted),
      );
    }
    if ("includeHistory" in patch) {
      viewPreferences.changePreference(
        "include_history",
        Boolean(patch.includeHistory),
      );
    }
    if ("priority" in patch) {
      viewPreferences.changePreference(
        "filter_priority",
        patch.priority ?? null,
      );
    }
    if ("dueFilter" in patch) {
      viewPreferences.changePreference("filter_due", patch.dueFilter ?? null);
    }
    if ("labelFilters" in patch) {
      viewPreferences.changePreference(
        "filter_labels",
        (patch.labelFilters ?? []).map(({ board_id, label_id }) => ({
          board_id,
          label_id,
        })),
      );
    }
    if ("order" in patch) {
      viewPreferences.changePreference("order", patch.order ?? "due");
    }
    if (
      viewPreferences.state.context.type !== "search_my_tasks" &&
      ("assigneeId" in patch || "unassigned" in patch)
    ) {
      viewPreferences.changePreference("filter_responsibility", {
        assignee_id:
          "assigneeId" in patch ? (patch.assigneeId ?? null) : state.assigneeId,
        unassigned: patch.unassigned ?? state.unassigned,
      });
    }
    const navigationPatch: Partial<typeof navigationState> = {};
    if ("query" in patch) navigationPatch.query = patch.query ?? "";
    if ("mode" in patch) navigationPatch.mode = patch.mode ?? "suggestions";
    setNavigationState((current) => ({ ...current, ...navigationPatch }));
  }

  function changeScope(
    scope: UnifiedSearchScope,
    boardSlug: string | null,
    switchPreferences = true,
  ) {
    setPageCursor(null);
    setHasMore(false);
    setNextCursor(null);
    setResults([]);
    setScopeUnavailable(false);
    setAccessUnavailable(false);
    const board =
      scope === "board" ? boards.find((item) => item.slug === boardSlug) : null;
    if (scope === "board" && !board) {
      setNavigationState((current) => ({ ...current, scope, boardSlug }));
      setScopeUnavailable(true);
      return;
    }
    const nextContext: ViewPreferenceContext =
      scope === "my_tasks"
        ? { type: "search_my_tasks", boardId: null }
        : scope === "board"
          ? { type: "search_board", boardId: board?.id ?? null }
          : { type: "search_all", boardId: null };
    if (
      switchPreferences &&
      viewPreferences.state.contextKey !==
        (nextContext.boardId
          ? `${nextContext.type}:${nextContext.boardId.toLowerCase()}`
          : nextContext.type)
    ) {
      void viewPreferences.switchContext(nextContext);
    }
    setNavigationState((current) => ({ ...current, scope, boardSlug }));
  }

  async function applySavedView(
    definition: SavedViewDefinition,
    invalidReferences: SavedViewReferenceField[] = [],
  ) {
    const requestedBoard =
      definition.scope === "board"
        ? boards.find((board) => board.id === definition.boardId)
        : null;
    const boardScopeNeedsReplacement =
      definition.scope === "board" &&
      (!requestedBoard || invalidReferences.includes("boardId"));
    if (boardScopeNeedsReplacement || invalidReferences.length > 0) {
      setPendingSavedViewReview({
        definition,
        invalidReferences,
        boardScopeNeedsReplacement,
      });
      setResults([]);
      setHasMore(false);
      setNextCursor(null);
      setPageCursor(null);
      setMessage(
        boardScopeNeedsReplacement
          ? "El tablero de esta vista ya no está disponible. Elige un tablero específico y accesible en «Buscar en» para reemplazar su alcance; la búsqueda no se ampliará mientras tanto. La consulta y los filtros quedan pausados hasta resolver o cancelar la revisión."
          : "Esta vista tiene condiciones que ya no están disponibles. No mostramos sus valores ni resultados. Elige qué condiciones quitar; la consulta y los filtros quedan pausados hasta resolver o cancelar la revisión.",
      );
      return;
    }
    const scope: UnifiedSearchScope = definition.scope;
    const boardSlug = scope === "board" ? (requestedBoard?.slug ?? null) : null;
    const nextPreferenceContext: ViewPreferenceContext =
      scope === "my_tasks"
        ? { type: "search_my_tasks", boardId: null }
        : scope === "board"
          ? { type: "search_board", boardId: requestedBoard?.id ?? null }
          : { type: "search_all", boardId: null };
    const nextContextKey = nextPreferenceContext.boardId
      ? `${nextPreferenceContext.type}:${nextPreferenceContext.boardId.toLowerCase()}`
      : nextPreferenceContext.type;
    const contextLoad =
      viewPreferences.state.contextKey === nextContextKey
        ? Promise.resolve()
        : viewPreferences.switchContext(nextPreferenceContext);
    changeScope(scope, boardSlug, false);
    await contextLoad;
    updateState({
      query: definition.query,
      filterBoardId: definition.filterBoardId,
      includeCompleted: definition.includeCompleted,
      includeHistory: definition.includeHistory,
      priority: definition.priority,
      assigneeId: definition.assigneeId,
      unassigned: definition.unassigned,
      dueFilter: definition.dueFilter,
      labelFilters: definition.labels.map(({ boardId, labelId }) => {
        const knownLabel = labelNames.get(`${boardId}:${labelId}`);
        return {
          board_id: boardId,
          label_id: labelId,
          label_name: knownLabel?.label_name ?? null,
          board_name:
            knownLabel?.board_name ??
            boards.find((board) => board.id === boardId)?.name ??
            null,
        };
      }),
      order: definition.order,
    });
    setPendingSavedViewReview(null);
    setScopeUnavailable(false);
    setMessage("");
  }

  async function removeUnavailableViewCondition(
    field: SavedViewReferenceField,
  ) {
    const review = pendingSavedViewReview;
    if (
      !review ||
      review.boardScopeNeedsReplacement ||
      field === "boardId" ||
      !review.invalidReferences.includes(field)
    ) {
      return;
    }

    const definition = removeSavedViewCondition(review.definition, field);
    const invalidReferences = review.invalidReferences.filter(
      (current) => current !== field,
    );
    if (invalidReferences.length > 0) {
      setPendingSavedViewReview({
        ...review,
        definition,
        invalidReferences,
      });
      setMessage(
        "Quedan otras condiciones no disponibles. Elige cuáles quitar o cancela la revisión.",
      );
      return;
    }

    await applySavedView(definition);
    setMessage(
      "Quitaste las condiciones elegidas. Puedes agregar condiciones accesibles y revisar el resultado; pulsa «Confirmar revisión y actualizar» para guardar los cambios.",
    );
  }

  function toggleLabel(result: UnifiedSearchResult) {
    if (result.kind !== "label") return;
    const key = `${String(result.board_id)}:${String(result.label_id)}`;
    const existing = selectedFilters.has(key);
    const next = existing
      ? state.labelFilters.filter(
          (filter) => `${filter.board_id}:${filter.label_id}` !== key,
        )
      : [
          ...state.labelFilters,
          {
            board_id: String(result.board_id),
            label_id: String(result.label_id),
            label_name: String(result.label_name),
            board_name: String(result.board_name),
          },
        ];
    if (!existing) {
      setLabelNames((current) =>
        new Map(current).set(key, {
          board_id: String(result.board_id),
          label_id: String(result.label_id),
          label_name: String(result.label_name),
          board_name: String(result.board_name),
        }),
      );
    }
    updateState({ labelFilters: next });
  }

  const groups =
    state.mode === "tasks"
      ? (["task"] as const)
      : (["task", "comment", "board", "label"] as const);

  return (
    <main className="mx-auto min-h-dvh max-w-6xl bg-surface-base px-4 py-6 text-text-primary sm:px-8 sm:py-10">
      <header className="mb-6 flex flex-wrap items-center justify-between gap-3 border-border border-b pb-5">
        <div>
          <Link
            href={backHref(state)}
            className="text-sm text-text-secondary underline underline-offset-4 hover:text-text-primary"
          >
            Volver
          </Link>
          <h1 className="mt-3 font-bold font-display text-3xl">Buscar</h1>
          <p className="mt-1 text-sm text-text-secondary">
            Busca tareas, comentarios y tableros a los que tienes acceso.
          </p>
        </div>
        <Link
          href="/"
          className="rounded-lg border border-border px-3 py-2 text-sm text-text-secondary hover:bg-surface-hover"
        >
          Inicio
        </Link>
      </header>

      {!accessUnavailable && !scopeUnavailable ? (
        <ViewPreferenceStatus
          state={viewPreferences.state}
          loadFailed={viewPreferences.loadFailed}
          onRetry={viewPreferences.retryPreference}
          onRetryLoad={viewPreferences.retryLoad}
          onResolveConflict={viewPreferences.resolveConflict}
          onClearReference={(key) => {
            if (key === "filter_board") updateState({ filterBoardId: null });
            if (key === "filter_due") updateState({ dueFilter: null });
            if (key === "filter_labels") updateState({ labelFilters: [] });
            if (key === "filter_priority") updateState({ priority: null });
            if (key === "filter_responsibility") {
              updateState({ assigneeId: null, unassigned: false });
            }
          }}
          resetConflict={viewPreferences.resetConflict}
          resetFailed={viewPreferences.resetFailed}
          onResolveResetConflict={viewPreferences.resolveResetConflict}
          onRetryReset={viewPreferences.resetPreferences}
        />
      ) : null}
      {preferenceControlStatusMessage ? (
        <output
          id="search-preference-control-status"
          aria-live="polite"
          className="mb-3 block text-sm text-text-secondary"
        >
          {preferenceControlStatusMessage}
        </output>
      ) : null}

      <SavedViewsPanel
        key={accountId}
        context="search"
        currentDefinition={currentSavedViewDefinition}
        canEditCurrentDefinition={!pendingSavedViewReview}
        canApplySelectedView={!pendingSavedViewReview}
        initialSnapshot={initialSavedViews}
        onApply={applySavedView}
      />

      {accessUnavailable ? (
        <section className="rounded-2xl border border-border bg-surface-raised p-6">
          <h2 className="font-semibold text-lg">Acceso no disponible</h2>
          <p className="mt-2 text-sm text-text-secondary">
            Se quitó la vista previa y los filtros privados de esta cuenta.
            Vuelve a la página inicial para comprobar el acceso actual.
          </p>
          <Link
            href="/"
            className="mt-4 inline-flex rounded-lg bg-accent px-4 py-2 font-medium text-accent-foreground text-sm"
          >
            Ir al inicio
          </Link>
        </section>
      ) : scopeUnavailable && !pendingSavedViewReview ? (
        <section className="rounded-2xl border border-border bg-surface-raised p-6">
          <h2 className="font-semibold text-lg">Tablero no disponible</h2>
          <p className="mt-2 text-sm text-text-secondary">
            No se muestran nombres ni resultados almacenados de ese tablero.
            Puedes empezar una búsqueda nueva en tus tableros accesibles.
          </p>
          <button
            type="button"
            onClick={() => {
              const params = new URLSearchParams({
                scope: "all",
                q: state.query,
              });
              window.location.assign(`/search?${params.toString()}`);
            }}
            className="mt-4 rounded-lg bg-accent px-4 py-2 font-medium text-accent-foreground text-sm"
          >
            Buscar en todos mis tableros accesibles
          </button>
        </section>
      ) : (
        <section className="grid gap-5 lg:grid-cols-[19rem_minmax(0,1fr)]">
          <aside className="h-fit rounded-2xl border border-border bg-surface-raised p-4">
            <label
              htmlFor="unified-search-query"
              className="mb-2 block font-medium text-sm"
            >
              Consulta
            </label>
            <div className="flex items-center gap-2 rounded-xl border border-border bg-surface-base px-3 focus-within:outline-2 focus-within:outline-focus-ring">
              <IconSearch
                aria-hidden="true"
                size={18}
                className="shrink-0 text-text-muted"
              />
              <input
                ref={queryInputRef}
                id="unified-search-query"
                type="search"
                maxLength={200}
                value={state.query}
                disabled={Boolean(pendingSavedViewReview)}
                onChange={(event) => updateState({ query: event.target.value })}
                placeholder="Tarea, comentario o tablero"
                className="min-h-12 w-full bg-transparent text-sm outline-none placeholder:text-text-muted"
              />
              {state.query ? (
                <button
                  type="button"
                  disabled={Boolean(pendingSavedViewReview)}
                  onClick={() => updateState({ query: "" })}
                  aria-label="Borrar consulta"
                  className="rounded p-1 text-text-secondary hover:bg-surface-hover"
                >
                  <IconX aria-hidden="true" size={16} />
                </button>
              ) : null}
            </div>

            <label
              htmlFor="search-scope"
              className="mt-5 mb-1 block font-medium text-sm"
            >
              Buscar en
            </label>
            <select
              id="search-scope"
              value={
                state.scope === "board"
                  ? `board:${state.boardSlug ?? ""}`
                  : state.scope
              }
              disabled={Boolean(
                pendingSavedViewReview &&
                  !pendingSavedViewReview.boardScopeNeedsReplacement,
              )}
              onChange={(event) => {
                if (pendingSavedViewReview?.boardScopeNeedsReplacement) {
                  if (event.target.value.startsWith("board:")) {
                    const replacementBoard = boards.find(
                      (board) =>
                        board.slug ===
                        event.target.value.slice("board:".length),
                    );
                    if (!replacementBoard) return;
                    const { definition, invalidReferences } =
                      pendingSavedViewReview;
                    void applySavedView(
                      { ...definition, boardId: replacementBoard.id },
                      invalidReferences.filter((field) => field !== "boardId"),
                    );
                    return;
                  }
                  setMessage(
                    "Para conservar el alcance limitado, elige un tablero específico y accesible.",
                  );
                  return;
                }
                if (pendingSavedViewReview) {
                  setMessage(
                    "Resuelve o cancela la revisión de condiciones antes de cambiar el alcance.",
                  );
                  return;
                }
                if (
                  event.target.value === "all" ||
                  event.target.value === "my_tasks"
                ) {
                  changeScope(event.target.value, null);
                } else {
                  changeScope("board", event.target.value.slice(6));
                }
              }}
              className="min-h-11 w-full rounded-lg border border-border bg-surface-base px-3 text-sm"
            >
              <option value="all">Todos mis tableros</option>
              <option value="my_tasks">Mis tareas asignadas</option>
              {boards.map((board) => (
                <option key={board.id} value={`board:${board.slug}`}>
                  {board.name}
                </option>
              ))}
              {state.scope === "board" && !selectedBoard ? (
                <option value={`board:${state.boardSlug ?? ""}`}>
                  Tablero ya no disponible
                </option>
              ) : null}
            </select>

            <label
              htmlFor="search-board-filter"
              className="mt-4 mb-1 block font-medium text-sm"
            >
              Acotar por tablero
            </label>
            <select
              id="search-board-filter"
              value={state.filterBoardId ?? ""}
              {...preferenceControlProps("filter_board")}
              onChange={(event) =>
                updateState({ filterBoardId: event.target.value || null })
              }
              className="min-h-11 w-full rounded-lg border border-border bg-surface-base px-3 text-sm disabled:opacity-50"
            >
              <option value="">Cualquier tablero accesible</option>
              {boards.map((board) => (
                <option key={board.id} value={board.id}>
                  {board.name}
                </option>
              ))}
              {state.filterBoardId &&
              !boards.some((board) => board.id === state.filterBoardId) ? (
                <option value={state.filterBoardId}>
                  Tablero no disponible
                </option>
              ) : null}
            </select>
            {state.scope === "board" ? (
              <p className="mt-2 text-text-muted text-xs">
                La búsqueda está limitada al tablero de origen.
              </p>
            ) : state.scope === "my_tasks" ? (
              <p className="mt-2 text-text-muted text-xs">
                Los comentarios coinciden solo si pertenecen a una tarea
                asignada a ti.
              </p>
            ) : null}

            <fieldset
              disabled={Boolean(pendingSavedViewReview)}
              className="mt-5 space-y-2 border-0 p-0"
            >
              <legend className="mb-2 font-medium text-sm">Incluir</legend>
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={state.includeCompleted}
                  {...preferenceControlProps("include_completed")}
                  onChange={(event) =>
                    updateState({ includeCompleted: event.target.checked })
                  }
                />
                Tareas completadas
              </label>
              <label className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={state.includeHistory}
                  {...preferenceControlProps("include_history")}
                  onChange={(event) =>
                    updateState({ includeHistory: event.target.checked })
                  }
                />
                Historial de repeticiones
              </label>
            </fieldset>

            <label
              htmlFor="search-priority"
              className="mt-5 mb-1 block font-medium text-sm"
            >
              Prioridad
            </label>
            <select
              id="search-priority"
              value={state.priority ?? ""}
              {...preferenceControlProps("filter_priority")}
              onChange={(event) =>
                updateState({
                  priority: (event.target.value ||
                    null) as SearchUiState["priority"],
                })
              }
              className="min-h-11 w-full rounded-lg border border-border bg-surface-base px-3 text-sm disabled:opacity-50"
            >
              <option value="">Cualquier prioridad</option>
              <option value="urgent">Urgente</option>
              <option value="high">Alta</option>
              <option value="medium">Media</option>
              <option value="low">Baja</option>
            </select>

            <label
              htmlFor="search-due"
              className="mt-4 mb-1 block font-medium text-sm"
            >
              Fecha
            </label>
            <select
              id="search-due"
              value={state.dueFilter ?? ""}
              {...preferenceControlProps("filter_due")}
              onChange={(event) =>
                updateState({
                  dueFilter: (event.target.value ||
                    null) as SearchUiState["dueFilter"],
                })
              }
              className="min-h-11 w-full rounded-lg border border-border bg-surface-base px-3 text-sm disabled:opacity-50"
            >
              <option value="">Cualquier fecha</option>
              <option value="today">Hoy (zona del tablero)</option>
              <option value="overdue">Atrasadas</option>
              <option value="next_7_days">Próximos 7 días</option>
              <option value="no_date">Sin fecha</option>
            </select>

            {state.scope !== "my_tasks" ? (
              <>
                <label
                  htmlFor="search-assignee"
                  className="mt-4 mb-1 block font-medium text-sm"
                >
                  Responsable
                </label>
                <select
                  id="search-assignee"
                  value={state.assigneeId ?? ""}
                  {...preferenceControlProps("filter_responsibility")}
                  onChange={(event) =>
                    updateState({
                      assigneeId: event.target.value || null,
                      unassigned: false,
                    })
                  }
                  className="min-h-11 w-full rounded-lg border border-border bg-surface-base px-3 text-sm disabled:opacity-50"
                >
                  <option value="">Cualquier persona</option>
                  {assignees.map((assignee) => (
                    <option key={assignee.user_id} value={assignee.user_id}>
                      {assignee.name} · {assignee.board_name}
                    </option>
                  ))}
                  {state.assigneeId &&
                  !assignees.some(
                    (assignee) => assignee.user_id === state.assigneeId,
                  ) ? (
                    <option value={state.assigneeId}>
                      Responsable no disponible
                    </option>
                  ) : null}
                </select>
                <label className="mt-3 flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={state.unassigned}
                    {...preferenceControlProps("filter_responsibility")}
                    onChange={(event) =>
                      updateState({
                        unassigned: event.target.checked,
                        assigneeId: null,
                      })
                    }
                  />
                  Sin responsable
                </label>
              </>
            ) : null}

            {state.labelFilters.length > 0 ? (
              <div className="mt-5">
                <h2 className="font-medium text-sm">Etiquetas · cualquiera</h2>
                <ul className="mt-2 space-y-2">
                  {state.labelFilters.map((filter) => (
                    <li key={`${filter.board_id}:${filter.label_id}`}>
                      <button
                        type="button"
                        onClick={() =>
                          updateState({
                            labelFilters: state.labelFilters.filter(
                              (item) =>
                                item.label_id !== filter.label_id ||
                                item.board_id !== filter.board_id,
                            ),
                          })
                        }
                        {...preferenceControlProps("filter_labels")}
                        className="flex w-full items-center justify-between gap-2 rounded-lg border border-border px-2 py-2 text-left text-xs hover:bg-surface-hover disabled:opacity-50"
                      >
                        <span>
                          {filter.label_name ?? "Etiqueta guardada"} ·{" "}
                          {filter.board_name ?? "tablero no disponible"}
                        </span>
                        <IconX aria-hidden="true" size={14} />
                      </button>
                    </li>
                  ))}
                </ul>
              </div>
            ) : null}
          </aside>

          <section aria-labelledby="search-results-heading" className="min-w-0">
            <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
              <div>
                <h2
                  id="search-results-heading"
                  className="font-semibold text-xl"
                >
                  {state.mode === "tasks"
                    ? "Tareas que coinciden"
                    : "Coincidencias"}
                </h2>
                <p className="mt-1 text-sm text-text-secondary">
                  {state.mode === "tasks"
                    ? `Orden personal: ${state.order === "created" ? "creación" : "vencimiento"}.`
                    : "Las coincidencias se agrupan por tipo y relevancia."}
                </p>
              </div>
              <div className="flex flex-wrap gap-2">
                <button
                  type="button"
                  onClick={viewPreferences.resetPreferences}
                  disabled={
                    viewPreferences.state.accessLost ||
                    Boolean(pendingSavedViewReview)
                  }
                  className="rounded-lg border border-border px-3 py-2 text-sm text-text-secondary hover:bg-surface-hover disabled:opacity-50"
                >
                  Reiniciar preferencias
                </button>
                {state.scope !== "all" ? (
                  <button
                    type="button"
                    disabled={Boolean(pendingSavedViewReview)}
                    onClick={() => changeScope("all", null)}
                    className="rounded-lg border border-border px-3 py-2 text-sm text-text-secondary hover:bg-surface-hover"
                  >
                    Buscar en todos los tableros accesibles
                  </button>
                ) : null}
                <button
                  type="button"
                  disabled={
                    Boolean(pendingSavedViewReview) ||
                    isClearBlocked ||
                    (!state.query &&
                      !state.filterBoardId &&
                      !state.includeCompleted &&
                      !state.includeHistory &&
                      !state.priority &&
                      !state.assigneeId &&
                      !state.unassigned &&
                      !state.dueFilter &&
                      state.labelFilters.length === 0)
                  }
                  onClick={() => updateState(clearUnifiedSearchFilters(state))}
                  className="rounded-lg border border-border px-3 py-2 text-sm text-text-secondary hover:bg-surface-hover disabled:cursor-not-allowed disabled:opacity-50"
                >
                  Limpiar
                </button>
                {state.mode === "suggestions" ? (
                  <button
                    type="button"
                    disabled={Boolean(pendingSavedViewReview)}
                    onClick={() => updateState({ mode: "tasks" })}
                    className="rounded-lg bg-accent px-3 py-2 font-medium text-accent-foreground text-sm hover:bg-accent-hover"
                  >
                    Ver tareas que coinciden
                  </button>
                ) : (
                  <>
                    <label className="flex items-center gap-2 text-sm text-text-secondary">
                      Orden
                      <select
                        value={state.order}
                        {...preferenceControlProps("order")}
                        onChange={(event) =>
                          updateState({
                            order: event.target.value as SearchUiState["order"],
                          })
                        }
                        className="min-h-10 rounded-lg border border-border bg-surface-raised px-2 disabled:opacity-50"
                      >
                        <option value="due">Vencimiento</option>
                        <option value="created">Creación</option>
                      </select>
                    </label>
                    <button
                      type="button"
                      disabled={Boolean(pendingSavedViewReview)}
                      onClick={() => updateState({ mode: "suggestions" })}
                      className="rounded-lg border border-border px-3 py-2 text-sm hover:bg-surface-hover"
                    >
                      Volver a coincidencias
                    </button>
                  </>
                )}
              </div>
            </div>

            {state.includeHistory ? (
              <p className="mb-3 flex items-center gap-2 rounded-lg border border-border bg-surface-raised px-3 py-2 text-sm text-text-secondary">
                <IconHistory aria-hidden="true" size={17} />
                El historial reemplazado se muestra aparte de tareas completadas
                y se abre en modo de solo lectura.
              </p>
            ) : null}
            {state.scope === "all" && state.mode === "suggestions" ? (
              <p className="mb-3 rounded-lg border border-border bg-surface-raised px-3 py-2 text-text-secondary text-xs">
                Prioridad, fecha, responsable, etiquetas y estado se aplican a
                tareas y comentarios. Los tableros se buscan por nombre y
                aparecen como navegación independiente.
              </p>
            ) : null}
            {message ? (
              <output
                aria-live="polite"
                className="mb-3 block rounded-lg border border-border bg-surface-raised px-4 py-3 text-sm text-text-secondary"
              >
                <span>{message}</span>
                {pendingSavedViewReview ? (
                  <>
                    {!pendingSavedViewReview.boardScopeNeedsReplacement ? (
                      <span className="ml-3 inline-flex flex-wrap gap-2">
                        {pendingSavedViewReview.invalidReferences.map(
                          (field) => {
                            const label =
                              unavailableReferenceActionLabel(field);
                            return label ? (
                              <button
                                key={field}
                                type="button"
                                onClick={() =>
                                  void removeUnavailableViewCondition(field)
                                }
                                className="underline underline-offset-4"
                              >
                                {label}
                              </button>
                            ) : null;
                          },
                        )}
                      </span>
                    ) : null}
                    <button
                      type="button"
                      onClick={() => {
                        setPendingSavedViewReview(null);
                        setMessage("");
                      }}
                      className="ml-3 underline underline-offset-4"
                    >
                      Cancelar revisión
                    </button>
                  </>
                ) : null}
                {message.startsWith("No se pudo buscar") ? (
                  <button
                    type="button"
                    disabled={loading}
                    onClick={() => {
                      setMessage("");
                      stalePageRestartRef.current = false;
                      setResults([]);
                      setPageCursor(null);
                      setNextCursor(null);
                      setHasMore(false);
                      setRefreshNonce((current) => current + 1);
                    }}
                    className="ml-3 underline underline-offset-4 disabled:opacity-60"
                  >
                    Reintentar
                  </button>
                ) : null}
              </output>
            ) : null}

            {groups.map((kind) => {
              const groupResults = results.filter(
                (result) => result.kind === kind,
              );
              if (groupResults.length === 0) return null;
              return (
                <section
                  key={kind}
                  aria-label={groupLabels[kind]}
                  className="mb-5"
                >
                  <h3 className="mb-2 font-semibold text-text-muted text-xs uppercase tracking-wide">
                    {groupLabels[kind]}
                  </h3>
                  <ul className="space-y-2">
                    {groupResults.map((result) => {
                      const href = buildUnifiedSearchResultHref(result);
                      const labelKey = `${String(result.board_id)}:${String(result.label_id)}`;
                      const labelSelected = selectedFilters.has(labelKey);
                      return (
                        <li
                          key={`${result.kind}:${String(result.comment_id ?? result.occurrence_id ?? result.task_id ?? result.label_id ?? result.board_id)}:${String(result.field)}`}
                        >
                          <article className="rounded-xl border border-border bg-surface-raised p-4 transition hover:border-border-hover">
                            <div className="flex flex-wrap items-start justify-between gap-3">
                              <div className="min-w-0 flex-1">
                                <p className="text-text-muted text-xs">
                                  {resultFieldLabel(result)} ·{" "}
                                  {resultOrigin(result)}
                                </p>
                                {href ? (
                                  <Link
                                    href={href}
                                    className="mt-1 inline-block font-semibold text-text-primary underline decoration-transparent underline-offset-4 hover:decoration-current focus-visible:outline"
                                  >
                                    {resultTitle(result)}
                                  </Link>
                                ) : (
                                  <h4 className="mt-1 font-semibold">
                                    {resultTitle(result)}
                                  </h4>
                                )}
                                {result.kind === "comment" ? (
                                  <p className="mt-1 text-text-secondary text-xs">
                                    {String(result.author_name ?? "Comentario")}{" "}
                                    · {String(result.column_title)}
                                  </p>
                                ) : null}
                                <p className="mt-2 whitespace-pre-wrap break-words text-sm text-text-secondary">
                                  {String(result.excerpt)}
                                </p>
                                {result.is_historical === true ? (
                                  <p className="mt-2 text-text-muted text-xs">
                                    Reemplazada · {String(result.occurrence_on)}{" "}
                                    · tarea de origen{" "}
                                    {String(result.origin_task_id).slice(0, 8)}
                                  </p>
                                ) : null}
                              </div>
                              {result.kind === "label" ? (
                                <button
                                  type="button"
                                  onClick={() => toggleLabel(result)}
                                  {...preferenceControlProps("filter_labels")}
                                  aria-pressed={labelSelected}
                                  className="shrink-0 rounded-lg border border-border px-3 py-2 text-sm hover:bg-surface-hover disabled:opacity-50"
                                >
                                  {labelSelected
                                    ? "Quitar filtro"
                                    : "Filtrar por etiqueta"}
                                </button>
                              ) : null}
                            </div>
                          </article>
                        </li>
                      );
                    })}
                  </ul>
                </section>
              );
            })}

            {loading ? (
              <output
                aria-live="polite"
                className="block py-5 text-center text-sm text-text-secondary"
              >
                Buscando…
              </output>
            ) : null}
            {state.mode === "tasks" && hasMore ? (
              <button
                type="button"
                disabled={
                  loading || !nextCursor || Boolean(pendingSavedViewReview)
                }
                onClick={() => setPageCursor(nextCursor)}
                className="mt-3 min-h-11 w-full rounded-lg border border-border px-4 py-2 text-sm hover:bg-surface-hover disabled:opacity-60"
              >
                Cargar más tareas
              </button>
            ) : null}
            <p className="mt-6 text-center text-text-muted text-xs">
              La búsqueda respeta los permisos actuales. No incluye archivos ni
              actividad.
            </p>
          </section>
        </section>
      )}
    </main>
  );
}
