export function reconcileRestoreSelection(
  currentIds: readonly string[],
  availableIds: readonly string[],
  preserveSelections: boolean,
): string[] {
  if (!preserveSelections) return [...availableIds];

  const available = new Set(availableIds);
  return currentIds.filter((id) => available.has(id));
}
