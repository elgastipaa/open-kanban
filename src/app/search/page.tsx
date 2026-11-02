import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { UnifiedSearchClient } from "@/components/search/unified-search-client";
import { resolveApplicationAccess } from "@/lib/auth";
import { listBoardLabels } from "@/lib/db/board-labels";
import { listAssignableBoardMembers } from "@/lib/db/my-tasks";
import { listMySavedViews } from "@/lib/db/saved-views";
import { getMyViewPreferences } from "@/lib/db/view-preferences";
import type { SavedViewsSnapshot } from "@/lib/saved-view-state";
import { createClient } from "@/lib/supabase/server";
import type {
  ViewPreferenceContext,
  ViewPreferenceDrafts,
  ViewPreferenceSnapshot,
} from "@/lib/view-preference-state";

export const metadata: Metadata = {
  title: "Buscar",
  description: "Busca tareas, comentarios y tableros accesibles.",
  robots: { index: false, follow: false, nocache: true },
};

interface SearchPageProps {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}

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

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function first(value: string | string[] | undefined): string | null {
  return typeof value === "string" ? value : null;
}

export default async function SearchPage({ searchParams }: SearchPageProps) {
  const query = await searchParams;
  const supabase = await createClient();
  const { data: authData } = await supabase.auth.getUser();
  if (!authData.user) redirect("/login?next=%2Fsearch");
  const access = await resolveApplicationAccess(supabase);
  if (access.status !== "active") redirect("/");

  const { data: rawBoards } = await supabase.rpc("list_my_boards");
  const boards: SearchBoardOption[] = Array.isArray(rawBoards)
    ? rawBoards.filter(
        (board): board is SearchBoardOption =>
          typeof board === "object" &&
          board !== null &&
          typeof board.id === "string" &&
          uuidPattern.test(board.id) &&
          typeof board.slug === "string" &&
          typeof board.name === "string",
      )
    : [];
  let initialSavedViews: SavedViewsSnapshot = { status: "error" };
  try {
    initialSavedViews = await listMySavedViews(supabase, "search");
  } catch {
    initialSavedViews = { status: "error" };
  }

  const scopeValue = first(query.scope);
  const invalidScope =
    scopeValue !== null &&
    scopeValue !== "all" &&
    scopeValue !== "board" &&
    scopeValue !== "my_tasks";
  const scope =
    scopeValue === "board" || scopeValue === "my_tasks" ? scopeValue : "all";
  const requestedBoardSlug = first(query.board_slug);
  const boardSlug =
    requestedBoardSlug && /^[a-z0-9-]{1,100}$/i.test(requestedBoardSlug)
      ? requestedBoardSlug
      : null;
  const initialBoard = boards.find((board) => board.slug === boardSlug) ?? null;
  const preferenceContext: ViewPreferenceContext =
    scope === "my_tasks"
      ? { type: "search_my_tasks", boardId: null }
      : scope === "board" && initialBoard
        ? { type: "search_board", boardId: initialBoard.id }
        : { type: "search_all", boardId: null };
  const initialScopeUnavailable =
    invalidScope || (scope === "board" && !initialBoard);
  let initialViewPreferences: ViewPreferenceSnapshot | null = null;
  let initialViewPreferencesLoadFailed = initialScopeUnavailable;
  if (!initialScopeUnavailable) {
    try {
      initialViewPreferences = await getMyViewPreferences(
        supabase,
        preferenceContext,
      );
    } catch {
      initialViewPreferencesLoadFailed = true;
    }
  }
  const savedPreferences = initialViewPreferences?.preferences ?? {};
  const hasSerializedViewState = first(query.view_state) === "1";
  const savedValue = (key: string, fallback: unknown) =>
    savedPreferences[key]?.value ?? fallback;
  const filterBoardId = hasSerializedViewState
    ? first(query.filter_board_id)
    : typeof savedValue("filter_board", null) === "string"
      ? (savedValue("filter_board", null) as string)
      : null;
  const priorityValue = hasSerializedViewState
    ? first(query.priority)
    : savedValue("filter_priority", null);
  const priority =
    priorityValue === "low" ||
    priorityValue === "medium" ||
    priorityValue === "high" ||
    priorityValue === "urgent"
      ? priorityValue
      : null;
  const dueValue = hasSerializedViewState
    ? first(query.due)
    : savedValue("filter_due", null);
  const dueFilter =
    dueValue === "today" ||
    dueValue === "overdue" ||
    dueValue === "next_7_days" ||
    dueValue === "no_date"
      ? dueValue
      : null;
  const rawLabelFilters = hasSerializedViewState
    ? Array.isArray(query.label)
      ? query.label
      : typeof query.label === "string"
        ? [query.label]
        : []
    : Array.isArray(savedValue("filter_labels", []))
      ? (
          savedValue("filter_labels", []) as Array<{
            board_id: string;
            label_id: string;
          }>
        ).map((item) => `${item.board_id}:${item.label_id}`)
      : [];
  const labelPairs = rawLabelFilters.slice(0, 100).flatMap((value) => {
    const [boardId, labelId, extra] = value.split(":");
    return !extra && uuidPattern.test(boardId) && uuidPattern.test(labelId)
      ? [{ board_id: boardId, label_id: labelId }]
      : [];
  });
  const labelLookupPairs = [
    ...labelPairs,
    ...(initialSavedViews.active_views ?? []).flatMap((view) =>
      view.definition.labels.map(({ boardId, labelId }) => ({
        board_id: boardId,
        label_id: labelId,
      })),
    ),
  ].filter(
    (pair, index, pairs) =>
      pairs.findIndex(
        (candidate) =>
          candidate.board_id === pair.board_id &&
          candidate.label_id === pair.label_id,
      ) === index,
  );
  const labelNames = new Map<string, { name: string; board_name: string }>();
  await Promise.all(
    [...new Set(labelLookupPairs.map((pair) => pair.board_id))].map(
      async (boardId) => {
        const board = boards.find((entry) => entry.id === boardId);
        if (!board) return;
        try {
          const labels = await listBoardLabels(supabase, board.slug);
          for (const pair of labelLookupPairs.filter(
            (item) => item.board_id === boardId,
          )) {
            const label = labels.find((entry) => entry.id === pair.label_id);
            if (label) {
              labelNames.set(`${boardId}:${label.id}`, {
                name: label.name,
                board_name: board.name,
              });
            }
          }
        } catch {
          // A stale or unavailable label remains removable by its stable IDs.
        }
      },
    ),
  );

  const relevantBoards =
    scope === "board" && initialBoard ? [initialBoard] : boards;
  const assignees: SearchAssigneeOption[] = [];
  await Promise.all(
    relevantBoards.map(async (board) => {
      try {
        const members = await listAssignableBoardMembers(supabase, board.slug);
        for (const member of members) {
          if (!assignees.some((entry) => entry.user_id === member.user_id)) {
            assignees.push({
              user_id: member.user_id,
              name: member.name,
              board_name: board.name,
            });
          }
        }
      } catch {
        // Search remains useful without the optional assignee choices.
      }
    }),
  );

  const orderValue = hasSerializedViewState
    ? first(query.order)
    : savedValue("order", "due");
  const modeValue = first(query.mode);
  const savedResponsibility = savedValue("filter_responsibility", {
    assignee_id: null,
    unassigned: false,
  }) as { assignee_id: string | null; unassigned: boolean };
  const assigneeCandidate = hasSerializedViewState
    ? first(query.assignee)
    : savedResponsibility.assignee_id;
  const unassigned = hasSerializedViewState
    ? first(query.unassigned) === "1"
    : savedResponsibility.unassigned;
  const includeCompleted = hasSerializedViewState
    ? first(query.completed) === "1"
    : savedValue("include_completed", false) === true;
  const includeHistory = hasSerializedViewState
    ? first(query.history) === "1"
    : savedValue("include_history", false) === true;
  const initialPreferenceDrafts: ViewPreferenceDrafts | undefined =
    hasSerializedViewState
      ? {
          filter_board: filterBoardId,
          filter_due: dueFilter,
          filter_labels: labelPairs.map(({ board_id, label_id }) => ({
            board_id,
            label_id,
          })),
          filter_priority: priority,
          include_completed: includeCompleted,
          include_history: includeHistory,
          order: orderValue === "created" ? "created" : "due",
          ...(preferenceContext.type === "search_my_tasks"
            ? {}
            : {
                filter_responsibility: {
                  assignee_id:
                    assigneeCandidate && uuidPattern.test(assigneeCandidate)
                      ? assigneeCandidate
                      : null,
                  unassigned,
                },
              }),
        }
      : undefined;
  return (
    <UnifiedSearchClient
      key={authData.user.id}
      accountId={authData.user.id}
      boards={boards}
      assignees={assignees}
      preferenceContext={preferenceContext}
      initialViewPreferences={initialViewPreferences}
      initialSavedViews={initialSavedViews}
      initialViewPreferencesLoadFailed={initialViewPreferencesLoadFailed}
      initialPreferenceDrafts={initialPreferenceDrafts}
      initialScopeUnavailable={initialScopeUnavailable}
      initialState={{
        query: (first(query.q) ?? "").slice(0, 200),
        scope,
        boardSlug: scope === "board" ? boardSlug : null,
        filterBoardId:
          filterBoardId && uuidPattern.test(filterBoardId)
            ? filterBoardId
            : null,
        includeCompleted,
        includeHistory,
        priority,
        assigneeId:
          assigneeCandidate && uuidPattern.test(assigneeCandidate)
            ? assigneeCandidate
            : null,
        unassigned,
        dueFilter,
        labelFilters: labelPairs.map((pair) => ({
          ...pair,
          label_name:
            labelNames.get(`${pair.board_id}:${pair.label_id}`)?.name ?? null,
          board_name:
            labelNames.get(`${pair.board_id}:${pair.label_id}`)?.board_name ??
            boards.find((board) => board.id === pair.board_id)?.name ??
            null,
        })),
        order: orderValue === "created" ? "created" : "due",
        mode: modeValue === "tasks" ? "tasks" : "suggestions",
      }}
    />
  );
}
