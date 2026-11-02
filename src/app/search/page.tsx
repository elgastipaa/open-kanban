import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { UnifiedSearchClient } from "@/components/search/unified-search-client";
import { resolveApplicationAccess } from "@/lib/auth";
import { listBoardLabels } from "@/lib/db/board-labels";
import { listAssignableBoardMembers } from "@/lib/db/my-tasks";
import { createClient } from "@/lib/supabase/server";

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

  const scopeValue = first(query.scope);
  const scope =
    scopeValue === "board" || scopeValue === "my_tasks" ? scopeValue : "all";
  const requestedBoardSlug = first(query.board_slug);
  const boardSlug =
    requestedBoardSlug && /^[a-z0-9-]{1,100}$/i.test(requestedBoardSlug)
      ? requestedBoardSlug
      : null;
  const initialBoard = boards.find((board) => board.slug === boardSlug) ?? null;
  const filterBoardId = first(query.filter_board_id);
  const priorityValue = first(query.priority);
  const priority =
    priorityValue === "low" ||
    priorityValue === "medium" ||
    priorityValue === "high" ||
    priorityValue === "urgent"
      ? priorityValue
      : null;
  const dueValue = first(query.due);
  const dueFilter =
    dueValue === "today" ||
    dueValue === "overdue" ||
    dueValue === "next_7_days" ||
    dueValue === "no_date"
      ? dueValue
      : null;
  const rawLabelFilters = Array.isArray(query.label)
    ? query.label
    : typeof query.label === "string"
      ? [query.label]
      : [];
  const labelPairs = rawLabelFilters.slice(0, 100).flatMap((value) => {
    const [boardId, labelId, extra] = value.split(":");
    return !extra && uuidPattern.test(boardId) && uuidPattern.test(labelId)
      ? [{ board_id: boardId, label_id: labelId }]
      : [];
  });
  const labelNames = new Map<string, { name: string; board_name: string }>();
  await Promise.all(
    [...new Set(labelPairs.map((pair) => pair.board_id))].map(
      async (boardId) => {
        const board = boards.find((entry) => entry.id === boardId);
        if (!board) return;
        try {
          const labels = await listBoardLabels(supabase, board.slug);
          for (const pair of labelPairs.filter(
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

  const orderValue = first(query.order);
  const modeValue = first(query.mode);
  const assigneeCandidate = first(query.assignee);
  return (
    <UnifiedSearchClient
      accountId={authData.user.id}
      boards={boards}
      assignees={assignees}
      initialState={{
        query: (first(query.q) ?? "").slice(0, 200),
        scope,
        boardSlug: scope === "board" ? boardSlug : null,
        filterBoardId:
          filterBoardId && uuidPattern.test(filterBoardId)
            ? filterBoardId
            : null,
        includeCompleted: first(query.completed) === "1",
        includeHistory: first(query.history) === "1",
        priority,
        assigneeId:
          assigneeCandidate && uuidPattern.test(assigneeCandidate)
            ? assigneeCandidate
            : null,
        unassigned: first(query.unassigned) === "1",
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
