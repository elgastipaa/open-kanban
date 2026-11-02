export type UnifiedSearchScope = "all" | "board" | "my_tasks";
export type UnifiedSearchMode = "suggestions" | "tasks";

export interface UnifiedSearchLabelFilter {
  board_id: string;
  label_id: string;
}

export interface UnifiedSearchCommand {
  query: string;
  scope: UnifiedSearchScope;
  boardSlug?: string | null;
  filterBoardId?: string | null;
  includeCompleted: boolean;
  includeHistory: boolean;
  priority?: "low" | "medium" | "high" | "urgent" | null;
  assigneeId?: string | null;
  unassigned: boolean;
  dueFilter?: "today" | "overdue" | "next_7_days" | "no_date" | null;
  labelFilters: UnifiedSearchLabelFilter[];
  order: "due" | "created";
  mode: UnifiedSearchMode;
  cursor?: Record<string, unknown> | null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function validUuid(value: unknown): value is string {
  return (
    typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      value,
    )
  );
}

function validCursor(
  value: unknown,
  order: unknown,
  mode: unknown,
): value is Record<string, unknown> | null | undefined {
  if (value == null) return true;
  if (mode !== "tasks" || !isRecord(value)) return false;
  if (
    !validUuid(value.id) ||
    typeof value.created_at !== "string" ||
    !Number.isFinite(Date.parse(value.created_at))
  ) {
    return false;
  }
  const keys = Object.keys(value).sort().join(",");
  if (order === "created") return keys === "created_at,id";
  if (
    keys !== "created_at,due_on,id" ||
    (value.due_on !== null &&
      (typeof value.due_on !== "string" ||
        !/^\d{4}-\d{2}-\d{2}$/.test(value.due_on)))
  ) {
    return false;
  }
  if (typeof value.due_on === "string") {
    try {
      if (
        new Date(`${value.due_on}T00:00:00.000Z`).toISOString().slice(0, 10) !==
        value.due_on
      ) {
        return false;
      }
    } catch {
      return false;
    }
  }
  return true;
}

export function parseUnifiedSearchRequest(
  value: unknown,
): UnifiedSearchCommand | null {
  if (!isRecord(value)) return null;
  const allowedKeys = new Set([
    "query",
    "scope",
    "boardSlug",
    "filterBoardId",
    "includeCompleted",
    "includeHistory",
    "priority",
    "assigneeId",
    "unassigned",
    "dueFilter",
    "labelFilters",
    "order",
    "mode",
    "cursor",
  ]);
  if (Object.keys(value).some((key) => !allowedKeys.has(key))) return null;

  const query = value.query;
  const scope = value.scope;
  const mode = value.mode;
  const order = value.order;
  if (
    typeof query !== "string" ||
    query.length > 200 ||
    !["all", "board", "my_tasks"].includes(String(scope)) ||
    !["suggestions", "tasks"].includes(String(mode)) ||
    !["due", "created"].includes(String(order)) ||
    (scope === "board" &&
      (typeof value.boardSlug !== "string" ||
        !/^[a-z0-9-]{1,100}$/i.test(value.boardSlug))) ||
    (value.filterBoardId != null && !validUuid(value.filterBoardId)) ||
    (value.assigneeId != null && !validUuid(value.assigneeId)) ||
    (value.priority != null &&
      !["low", "medium", "high", "urgent"].includes(String(value.priority))) ||
    (value.dueFilter != null &&
      !["today", "overdue", "next_7_days", "no_date"].includes(
        String(value.dueFilter),
      )) ||
    typeof value.includeCompleted !== "boolean" ||
    typeof value.includeHistory !== "boolean" ||
    typeof value.unassigned !== "boolean" ||
    !Array.isArray(value.labelFilters) ||
    value.labelFilters.length > 100 ||
    !value.labelFilters.every(
      (entry: unknown) =>
        isRecord(entry) &&
        validUuid(entry.board_id) &&
        validUuid(entry.label_id) &&
        Object.keys(entry).length === 2,
    ) ||
    !validCursor(value.cursor, order, mode)
  ) {
    return null;
  }

  return {
    query,
    scope: scope as UnifiedSearchScope,
    boardSlug: typeof value.boardSlug === "string" ? value.boardSlug : null,
    filterBoardId:
      typeof value.filterBoardId === "string" ? value.filterBoardId : null,
    includeCompleted: value.includeCompleted,
    includeHistory: value.includeHistory,
    priority:
      typeof value.priority === "string"
        ? (value.priority as UnifiedSearchCommand["priority"])
        : null,
    assigneeId: typeof value.assigneeId === "string" ? value.assigneeId : null,
    unassigned: value.unassigned,
    dueFilter:
      typeof value.dueFilter === "string"
        ? (value.dueFilter as UnifiedSearchCommand["dueFilter"])
        : null,
    labelFilters: value.labelFilters as UnifiedSearchLabelFilter[],
    order: order as UnifiedSearchCommand["order"],
    mode: mode as UnifiedSearchMode,
    cursor: isRecord(value.cursor) ? value.cursor : null,
  };
}
