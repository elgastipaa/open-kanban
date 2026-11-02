export interface UnifiedSearchResultNavigation {
  kind?: string;
  board_slug?: string | null;
  board_id?: string | null;
  task_id?: string | null;
  comment_id?: string | null;
  is_historical?: boolean;
  occurrence_state?: string | null;
  series_id?: string | null;
  occurrence_id?: string | null;
}

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const slugPattern = /^[a-z0-9-]{1,100}$/i;
const reservedPaths = new Set([
  "account",
  "admin",
  "auth",
  "invite",
  "login",
  "my-tasks",
  "notifications",
  "privacy",
  "search",
  "series",
  "terms",
]);

function safeBoardSlug(value: string | null | undefined): string | null {
  if (!value || !slugPattern.test(value)) return null;
  return value;
}

export interface GlobalSearchShortcutInput {
  key: string;
  ctrlKey: boolean;
  metaKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
  targetTag?: string | null;
  targetRole?: string | null;
  contentEditable?: boolean;
}

export function isGlobalSearchShortcut(
  input: GlobalSearchShortcutInput,
): boolean {
  return (
    input.key.toLowerCase() === "k" &&
    (input.ctrlKey || input.metaKey) &&
    !input.altKey &&
    !input.shiftKey &&
    !input.contentEditable &&
    !["input", "textarea", "select"].includes(
      input.targetTag?.toLowerCase() ?? "",
    ) &&
    !["textbox", "searchbox", "combobox"].includes(
      input.targetRole?.toLowerCase() ?? "",
    )
  );
}

export function buildUnifiedSearchHref(
  pathname: string,
  currentSearchParams: URLSearchParams,
): string {
  const params = new URLSearchParams();
  const cleanPath = pathname.replace(/\/$/, "") || "/";

  if (cleanPath === "/my-tasks") {
    params.set("scope", "my_tasks");
    const order = currentSearchParams.get("order");
    if (order === "created") params.set("order", order);
  } else if (cleanPath === "/search") {
    for (const key of [
      "q",
      "scope",
      "board_slug",
      "filter_board_id",
      "completed",
      "history",
      "priority",
      "assignee",
      "unassigned",
      "due",
      "label",
      "labels",
      "order",
      "mode",
    ]) {
      const values =
        key === "label"
          ? currentSearchParams.getAll(key)
          : [currentSearchParams.get(key) ?? ""];
      for (const value of values) {
        if (value) params.append(key, value);
      }
    }
  } else {
    const possibleSlug = cleanPath.startsWith("/")
      ? cleanPath.slice(1)
      : cleanPath;
    const boardSlug = safeBoardSlug(possibleSlug);
    if (boardSlug && !reservedPaths.has(boardSlug.toLowerCase())) {
      params.set("scope", "board");
      params.set("board_slug", boardSlug);
    } else {
      params.set("scope", "all");
    }
  }

  return `/search?${params.toString()}`;
}

export function buildUnifiedSearchResultHref(
  result: UnifiedSearchResultNavigation,
): string | null {
  if (result.kind === "label") return null;
  if (result.kind === "board") {
    const slug = safeBoardSlug(result.board_slug);
    return slug ? `/${encodeURIComponent(slug)}` : null;
  }
  if (result.kind !== "task" && result.kind !== "comment") return null;

  if (result.is_historical === true) {
    if (result.occurrence_state !== "replaced") return null;
    const boardId = result.board_id ?? "";
    const seriesId = result.series_id ?? "";
    const occurrenceId = result.occurrence_id ?? "";
    const commentId = result.kind === "comment" ? result.comment_id : null;
    if (
      !uuidPattern.test(boardId) ||
      !uuidPattern.test(seriesId) ||
      !uuidPattern.test(occurrenceId) ||
      (commentId != null && !uuidPattern.test(commentId))
    ) {
      return null;
    }
    const params = new URLSearchParams({
      board: boardId,
      series: seriesId,
      occurrence: occurrenceId,
    });
    if (commentId) params.set("comment", commentId);
    return `/series?${params.toString()}${commentId ? `#comment-${commentId}` : ""}`;
  }

  const slug = safeBoardSlug(result.board_slug);
  if (!slug || !result.task_id || !uuidPattern.test(result.task_id))
    return null;
  if (result.kind === "comment") {
    if (!result.comment_id || !uuidPattern.test(result.comment_id)) return null;
    return `/${encodeURIComponent(slug)}?task=${encodeURIComponent(result.task_id)}&comment=${encodeURIComponent(result.comment_id)}`;
  }
  return `/${encodeURIComponent(slug)}?task=${encodeURIComponent(result.task_id)}`;
}
