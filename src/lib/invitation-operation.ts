"use client";

export interface InvitationOperation {
  operationId: string;
  token: string | null;
}

export interface InvitationOperationStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

const STORAGE_PREFIX = "openkanban:invitation-operation:";
const OPERATION_ID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const TOKEN_PATTERN = /^[0-9a-f]{64}$/;
const fallbackStorage = new Map<string, string>();

function browserStorage(): InvitationOperationStorage | null {
  try {
    return typeof window === "undefined" ? null : window.sessionStorage;
  } catch {
    return null;
  }
}

function readStoredValue(
  key: string,
  storage: InvitationOperationStorage | null,
): string | null {
  try {
    const stored = storage?.getItem(key);
    if (stored !== null && stored !== undefined) return stored;
  } catch {
    // Fall back to the current module instance when session storage is blocked.
  }
  return fallbackStorage.get(key) ?? null;
}

function storeValue(
  key: string,
  value: string,
  storage: InvitationOperationStorage | null,
): void {
  try {
    if (storage) {
      storage.setItem(key, value);
      fallbackStorage.delete(key);
      return;
    }
  } catch {
    // Keep the retry key in memory for this page if session storage is blocked.
  }
  fallbackStorage.set(key, value);
}

function removeStoredValue(
  key: string,
  storage: InvitationOperationStorage | null,
): void {
  try {
    storage?.removeItem(key);
  } catch {
    // A failed session-storage cleanup must not block the confirmed command.
  }
  fallbackStorage.delete(key);
}

function parseStoredOperation(
  raw: string | null,
  tokenRequired: boolean,
): InvitationOperation | null {
  if (!raw) return null;
  try {
    const value: unknown = JSON.parse(raw);
    if (typeof value !== "object" || value === null || Array.isArray(value)) {
      return null;
    }
    const record = value as Record<string, unknown>;
    const keys = Object.keys(record).sort();
    if (
      keys.length !== 2 ||
      keys[0] !== "operationId" ||
      keys[1] !== "token" ||
      typeof record.operationId !== "string" ||
      !OPERATION_ID_PATTERN.test(record.operationId)
    ) {
      return null;
    }
    if (
      tokenRequired
        ? typeof record.token !== "string" || !TOKEN_PATTERN.test(record.token)
        : record.token !== null
    ) {
      return null;
    }
    return {
      operationId: record.operationId,
      token: record.token as string | null,
    };
  } catch {
    return null;
  }
}

function createToken(): string {
  const bytes = globalThis.crypto.getRandomValues(new Uint8Array(32));
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}

export function getOrCreateInvitationOperation(
  scope: string,
  tokenRequired: boolean,
  providedStorage?: InvitationOperationStorage,
): InvitationOperation {
  const storage = providedStorage ?? browserStorage();
  const key = `${STORAGE_PREFIX}${scope}`;
  const existing = parseStoredOperation(
    readStoredValue(key, storage),
    tokenRequired,
  );
  if (existing) return existing;

  const operation: InvitationOperation = {
    operationId: globalThis.crypto.randomUUID(),
    token: tokenRequired ? createToken() : null,
  };
  storeValue(key, JSON.stringify(operation), storage);
  return operation;
}

export function completeInvitationOperation(
  scope: string,
  providedStorage?: InvitationOperationStorage,
): void {
  const storage = providedStorage ?? browserStorage();
  removeStoredValue(`${STORAGE_PREFIX}${scope}`, storage);
}
