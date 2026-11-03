export function isRpcStatusResult(
  value: unknown,
): value is Record<string, unknown> & { status: string } {
  return (
    typeof value === "object" &&
    value !== null &&
    "status" in value &&
    typeof value.status === "string"
  );
}
