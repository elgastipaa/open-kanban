import type { SupabaseClient } from "@supabase/supabase-js";
import { getBoard } from "@/lib/db/boards";
import type { UnifiedSearchCommand } from "@/lib/unified-search-request";
export type UnifiedSearchRelevance = "exact" | "prefix" | "word";

export interface UnifiedSearchResult extends Record<string, unknown> {
  kind: "task" | "comment" | "board" | "label";
  field: string;
  relevance: UnifiedSearchRelevance;
  board_id: string;
  board_slug: string;
  board_name: string;
  excerpt: string;
}

export interface UnifiedSearchResponse {
  status: "available" | "scope_unavailable" | "unavailable" | "invalid_filter";
  results: UnifiedSearchResult[];
  has_more: boolean;
  next_cursor: Record<string, unknown> | null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isUnifiedSearchResult(value: unknown): value is UnifiedSearchResult {
  if (
    !isRecord(value) ||
    !["task", "comment", "board", "label"].includes(String(value.kind)) ||
    typeof value.field !== "string" ||
    !["exact", "prefix", "word"].includes(String(value.relevance)) ||
    typeof value.board_id !== "string" ||
    typeof value.board_slug !== "string" ||
    typeof value.board_name !== "string" ||
    typeof value.excerpt !== "string"
  ) {
    return false;
  }
  if (value.kind === "task") {
    return (
      typeof value.task_id === "string" &&
      typeof value.title === "string" &&
      typeof value.column_id === "string" &&
      typeof value.column_title === "string"
    );
  }
  if (value.kind === "comment") {
    return (
      typeof value.task_id === "string" &&
      typeof value.task_title === "string" &&
      typeof value.comment_id === "string" &&
      typeof value.column_id === "string" &&
      typeof value.column_title === "string"
    );
  }
  if (value.kind === "board") return true;
  return (
    typeof value.label_id === "string" && typeof value.label_name === "string"
  );
}

function isSearchResponse(value: unknown): value is UnifiedSearchResponse {
  return (
    isRecord(value) &&
    [
      "available",
      "scope_unavailable",
      "unavailable",
      "invalid_filter",
    ].includes(String(value.status)) &&
    Array.isArray(value.results) &&
    value.results.every(isUnifiedSearchResult) &&
    typeof value.has_more === "boolean" &&
    (value.next_cursor === null || isRecord(value.next_cursor))
  );
}

export async function searchUnified(
  supabase: SupabaseClient,
  command: UnifiedSearchCommand,
): Promise<UnifiedSearchResponse> {
  const scopeBoard =
    command.scope === "board" && command.boardSlug
      ? await getBoard(supabase, command.boardSlug)
      : null;
  if (command.scope === "board" && !scopeBoard) {
    return {
      status: "scope_unavailable",
      results: [],
      has_more: false,
      next_cursor: null,
    };
  }

  const { data, error } = await supabase.rpc("search_unified_p", {
    p_query: command.query,
    p_scope: command.scope,
    p_scope_board_id: scopeBoard?.id ?? null,
    p_filter_board_id: command.filterBoardId ?? null,
    p_include_completed: command.includeCompleted,
    p_include_history: command.includeHistory,
    p_priority: command.priority ?? null,
    p_assignee_id: command.assigneeId ?? null,
    p_unassigned: command.unassigned,
    p_due_filter: command.dueFilter ?? null,
    p_label_filters: command.labelFilters,
    p_order: command.order,
    p_mode: command.mode,
    p_limit: 24,
    p_cursor: command.cursor ?? null,
  });
  if (error) throw new Error("No se pudo realizar la búsqueda.");
  if (!isSearchResponse(data)) {
    throw new Error("La respuesta de búsqueda no es válida.");
  }
  return data;
}
