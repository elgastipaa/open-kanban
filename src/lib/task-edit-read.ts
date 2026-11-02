/** SQLSTATE 42501 is the database contract for a denied task-board read. */
export function isTaskEditReadAccessDeniedCode(
  code: string | null | undefined,
): boolean {
  return code === "42501";
}

export function classifyBoardSnapshotReadFailure(
  response: {
    error: { code?: string | null };
    status: number;
  },
): "denied" | "retryable" | "unavailable" {
  if (isTaskEditReadAccessDeniedCode(response.error.code)) return "denied";
  if (response.status === 0) return "retryable";
  return "unavailable";
}
