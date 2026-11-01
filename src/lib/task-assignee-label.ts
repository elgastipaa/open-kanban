export function getTaskAssigneeLabel(
  assigneeId: string | null,
  currentMemberNames: Readonly<Record<string, string>>,
): string | null {
  if (!assigneeId) return null;
  return currentMemberNames[assigneeId] ?? "Responsable no disponible";
}
