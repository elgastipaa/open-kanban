export interface BoardRestoreCommand {
  operationId: string;
  ownerId: string;
}

export type BoardRestoreCommandDecision =
  | { kind: "ready"; command: BoardRestoreCommand; isRetry: boolean }
  | { kind: "owner_required" }
  | { kind: "owner_locked"; command: BoardRestoreCommand };

export function adminMayResolveBoardRecovery(ownerIsValid: boolean): boolean {
  return !ownerIsValid;
}

export function prepareBoardRestoreCommand(
  selectedOwnerId: string,
  existingCommand: BoardRestoreCommand | null,
  createOperationId: () => string,
): BoardRestoreCommandDecision {
  if (!selectedOwnerId) return { kind: "owner_required" };
  if (existingCommand) {
    return existingCommand.ownerId === selectedOwnerId
      ? { kind: "ready", command: existingCommand, isRetry: true }
      : { kind: "owner_locked", command: existingCommand };
  }
  return {
    kind: "ready",
    isRetry: false,
    command: { operationId: createOperationId(), ownerId: selectedOwnerId },
  };
}
