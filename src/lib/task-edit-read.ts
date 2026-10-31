/** SQLSTATE 42501 is the database contract for a denied task-board read. */
export function isTaskEditReadAccessDeniedCode(
  code: string | null | undefined,
): boolean {
  return code === "42501";
}
