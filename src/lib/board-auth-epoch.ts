export function hasBoardAuthorizationEpochChanged(
  previousEpoch: string | number | null,
  currentEpoch: string | number,
): boolean {
  return (
    previousEpoch !== null && String(previousEpoch) !== String(currentEpoch)
  );
}

export function isBoardSnapshotForCurrentEpoch(
  currentEpoch: string | number,
  responseEpoch: string | number | null | undefined,
): boolean {
  return (
    responseEpoch !== null &&
    responseEpoch !== undefined &&
    String(currentEpoch) === String(responseEpoch)
  );
}

export function isBoardSnapshotForCurrentSession(
  requestSessionEpoch: number,
  currentSessionEpoch: number,
  requestBoardEpoch: string | number,
  currentBoardEpoch: string | number,
  responseBoardEpoch: string | number | null | undefined,
): boolean {
  return (
    requestSessionEpoch === currentSessionEpoch &&
    String(requestBoardEpoch) === String(currentBoardEpoch) &&
    isBoardSnapshotForCurrentEpoch(requestBoardEpoch, responseBoardEpoch)
  );
}
