export type UnifiedSearchFetch = (
  input: RequestInfo | URL,
  init?: RequestInit,
) => Promise<Response>;

export function postUnifiedSearch(
  fetcher: UnifiedSearchFetch,
  payload: Record<string, unknown>,
  signal: AbortSignal,
): Promise<Response> {
  return fetcher("/api/search", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    cache: "no-store",
    signal,
    body: JSON.stringify(payload),
  });
}

export function isCurrentUnifiedSearchRequest(
  requestId: number,
  currentRequestId: number,
  requestAccountId: string,
  currentAccountId: string,
): boolean {
  return (
    requestId === currentRequestId && requestAccountId === currentAccountId
  );
}

export function clearUnifiedSearchFilters<
  T extends {
    query: string;
    scope: string;
    boardSlug: string | null;
    filterBoardId: string | null;
    includeCompleted: boolean;
    includeHistory: boolean;
    priority: string | null;
    assigneeId: string | null;
    unassigned: boolean;
    dueFilter: string | null;
    labelFilters: unknown[];
    order: string;
    mode: string;
  },
>(state: T) {
  return {
    ...state,
    query: "",
    filterBoardId: null,
    includeCompleted: false,
    includeHistory: false,
    priority: null,
    assigneeId: null,
    unassigned: false,
    dueFilter: null,
    labelFilters: [],
  };
}
