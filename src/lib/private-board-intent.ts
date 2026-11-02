export interface SavedCreateBoardIntent {
  name: string;
  timeZone: string;
  operationId: string;
  uncertain: boolean;
}

export interface CreateBoardIntentStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

const intentStoragePrefix = "openkanban:create-board-intent";
const authUserIdPattern = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const operationIdPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function createBoardIntentStorageKey(
  principalId: string | null | undefined,
): string | null {
  if (!principalId || !authUserIdPattern.test(principalId)) return null;
  return `${intentStoragePrefix}:${principalId.toLowerCase()}`;
}

export function readCreateBoardIntent(
  storage: CreateBoardIntentStorage,
  principalId: string | null | undefined,
): SavedCreateBoardIntent | null {
  const key = createBoardIntentStorageKey(principalId);
  if (!key) return null;

  try {
    const value = storage.getItem(key);
    if (!value) return null;
    const parsed = JSON.parse(value) as SavedCreateBoardIntent;
    if (
      typeof parsed.name === "string" &&
      typeof parsed.timeZone === "string" &&
      typeof parsed.operationId === "string" &&
      operationIdPattern.test(parsed.operationId) &&
      typeof parsed.uncertain === "boolean"
    ) {
      return parsed;
    }
  } catch {
    return null;
  }
  return null;
}

export function saveCreateBoardIntent(
  storage: CreateBoardIntentStorage,
  principalId: string | null | undefined,
  intent: SavedCreateBoardIntent,
) {
  const key = createBoardIntentStorageKey(principalId);
  if (!key) return false;

  try {
    storage.setItem(key, JSON.stringify(intent));
    return true;
  } catch {
    return false;
  }
}

export function removeCreateBoardIntent(
  storage: CreateBoardIntentStorage,
  principalId: string | null | undefined,
) {
  const key = createBoardIntentStorageKey(principalId);
  if (!key) return;

  try {
    storage.removeItem(key);
  } catch {
    // Navigation can proceed without storage access.
  }
}
