export type ViewContextType =
  | "board"
  | "my_tasks"
  | "search_all"
  | "search_my_tasks"
  | "search_board";

export type ViewPreferenceContext = {
  type: ViewContextType;
  boardId: string | null;
};

export type ViewPreferenceValue =
  | string
  | boolean
  | null
  | string[]
  | Array<{ board_id: string; label_id: string }>
  | { assignee_id: string | null; unassigned: boolean }
  | { expanded: boolean; visible: boolean }
  | { collapsed: string[]; hidden: string[] };

export interface VersionedViewPreference {
  value: ViewPreferenceValue;
  version: number;
}

export type ViewPreferenceValues = Record<string, ViewPreferenceValue>;
export type ViewPreferenceVersions = Record<string, number>;
export type ViewPreferenceConflicts = Record<string, VersionedViewPreference>;
export type ViewPreferenceErrors = Record<string, string>;
export type ViewPreferenceModified = Record<string, boolean>;
export type ViewPreferenceDrafts = Record<string, ViewPreferenceValue>;
export type ViewPreferenceKey = string;

export interface ViewPreferenceSnapshot {
  status: "available" | "unavailable";
  context_type?: ViewContextType;
  board_id?: string | null;
  preferences?: Record<string, VersionedViewPreference>;
}

export type ViewPreferenceSaveResult =
  | {
      status: "saved" | "conflict";
      preference_key: string;
      value: ViewPreferenceValue;
      version: number;
    }
  | { status: "invalid_reference"; preference_key: string }
  | { status: "unavailable" }
  | { status: "error"; preference_key: string };

export type ViewPreferenceResetResult =
  | { status: "saved" | "conflict"; snapshot: ViewPreferenceSnapshot }
  | { status: "unavailable" }
  | { status: "error" };

export interface ViewPreferenceState {
  accountId: string | null;
  context: ViewPreferenceContext;
  contextKey: string;
  values: ViewPreferenceValues;
  versions: ViewPreferenceVersions;
  modified: ViewPreferenceModified;
  saving: Record<string, boolean>;
  conflicts: ViewPreferenceConflicts;
  errors: ViewPreferenceErrors;
  accessLost: boolean;
}

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isValidViewPreferenceContext(
  context: ViewPreferenceContext,
): boolean {
  const requiresBoard =
    context.type === "board" || context.type === "search_board";
  return requiresBoard
    ? typeof context.boardId === "string" && uuidPattern.test(context.boardId)
    : context.boardId === null;
}

export function isValidViewPreferenceValue(
  context: ViewPreferenceContext,
  preferenceKey: string,
  value: unknown,
): value is ViewPreferenceValue {
  if (!(preferenceKey in getViewPreferenceDefaults(context))) return false;

  if (preferenceKey === "labels") {
    return (
      context.type === "board" &&
      Array.isArray(value) &&
      value.length <= 100 &&
      value.every(
        (entry) => typeof entry === "string" && uuidPattern.test(entry),
      ) &&
      new Set(value.map((entry) => entry.toLowerCase())).size === value.length
    );
  }

  if (preferenceKey === "completed_view" && context.type === "board") {
    if (!isRecord(value) || !hasExactKeys(value, ["hidden", "collapsed"])) {
      return false;
    }
    return (
      isUniqueUuidList(value.hidden, 500) &&
      isUniqueUuidList(value.collapsed, 500)
    );
  }

  if (preferenceKey === "completed_view" && context.type === "my_tasks") {
    return (
      isRecord(value) &&
      hasExactKeys(value, ["visible", "expanded"]) &&
      typeof value.visible === "boolean" &&
      typeof value.expanded === "boolean"
    );
  }

  if (preferenceKey === "order") return value === "due" || value === "created";

  if (preferenceKey === "filter_board") {
    return (
      value === null || (typeof value === "string" && uuidPattern.test(value))
    );
  }

  if (preferenceKey === "filter_due") {
    return (
      value === null ||
      value === "today" ||
      value === "overdue" ||
      value === "next_7_days" ||
      value === "no_date"
    );
  }

  if (preferenceKey === "filter_priority") {
    return (
      value === null ||
      value === "low" ||
      value === "medium" ||
      value === "high" ||
      value === "urgent"
    );
  }

  if (preferenceKey === "filter_responsibility") {
    return (
      isRecord(value) &&
      hasExactKeys(value, ["assignee_id", "unassigned"]) &&
      (value.assignee_id === null ||
        (typeof value.assignee_id === "string" &&
          uuidPattern.test(value.assignee_id))) &&
      typeof value.unassigned === "boolean" &&
      !(value.assignee_id !== null && value.unassigned)
    );
  }

  if (preferenceKey === "filter_labels") {
    return (
      Array.isArray(value) &&
      value.length <= 100 &&
      value.every(
        (entry) =>
          isRecord(entry) &&
          hasExactKeys(entry, ["board_id", "label_id"]) &&
          typeof entry.board_id === "string" &&
          uuidPattern.test(entry.board_id) &&
          typeof entry.label_id === "string" &&
          uuidPattern.test(entry.label_id),
      ) &&
      new Set(
        value.map(
          (entry) =>
            `${entry.board_id.toLowerCase()}:${entry.label_id.toLowerCase()}`,
        ),
      ).size === value.length
    );
  }

  return (
    (preferenceKey === "include_completed" ||
      preferenceKey === "include_history") &&
    typeof value === "boolean"
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, keys: string[]): boolean {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  return (
    actual.length === expected.length &&
    actual.every((key, index) => key === expected[index])
  );
}

function isUniqueUuidList(value: unknown, maximum: number): value is string[] {
  return (
    Array.isArray(value) &&
    value.length <= maximum &&
    value.every(
      (entry) => typeof entry === "string" && uuidPattern.test(entry),
    ) &&
    new Set(value.map((entry) => entry.toLowerCase())).size === value.length
  );
}

function sameValue(left: unknown, right: unknown): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}

export function viewPreferenceContextKey(
  context: ViewPreferenceContext,
): string {
  return context.boardId
    ? `${context.type}:${context.boardId.toLowerCase()}`
    : context.type;
}

export function getViewPreferenceDefaults(
  context: ViewPreferenceContext,
): ViewPreferenceValues {
  if (context.type === "board") {
    return {
      labels: [],
      completed_view: { hidden: [], collapsed: [] },
    };
  }

  if (context.type === "my_tasks") {
    return {
      order: "due",
      completed_view: { visible: true, expanded: true },
    };
  }

  const defaults: ViewPreferenceValues = {
    filter_board: null,
    filter_due: null,
    filter_labels: [],
    filter_priority: null,
    include_completed: false,
    include_history: false,
    order: "due",
  };
  if (context.type !== "search_my_tasks") {
    defaults.filter_responsibility = {
      assignee_id: null,
      unassigned: false,
    };
  }
  return defaults;
}

export function createViewPreferenceState(
  accountId: string | null,
  context: ViewPreferenceContext,
  snapshot?: ViewPreferenceSnapshot | null,
  drafts: ViewPreferenceDrafts = {},
): ViewPreferenceState {
  const values = getViewPreferenceDefaults(context);
  const versions = Object.fromEntries(
    Object.keys(values).map((key) => [key, 0]),
  );
  const matchingSnapshot =
    snapshot?.status === "available" &&
    (!snapshot.context_type || snapshot.context_type === context.type) &&
    (snapshot.board_id === undefined || snapshot.board_id === context.boardId)
      ? snapshot.preferences
      : undefined;
  const conflicts: ViewPreferenceConflicts = {};
  const modified: ViewPreferenceModified = {};

  if (matchingSnapshot) {
    for (const [key, preference] of Object.entries(matchingSnapshot)) {
      if (
        key in values &&
        preference &&
        Number.isInteger(preference.version) &&
        preference.version >= 0
      ) {
        values[key] = preference.value;
        versions[key] = preference.version;
      }
    }
  }

  const accessLost = snapshot?.status === "unavailable";
  if (!accessLost) {
    for (const [key, value] of Object.entries(drafts)) {
      if (
        !(key in values) ||
        !isValidViewPreferenceValue(context, key, value)
      ) {
        continue;
      }
      const savedValue = values[key];
      if (!sameValue(savedValue, value)) {
        const savedVersion = versions[key] ?? 0;
        values[key] = value;
        modified[key] = true;
        if (matchingSnapshot?.[key]) {
          conflicts[key] = {
            value: savedValue,
            version: savedVersion,
          };
        }
      }
    }
  }

  return {
    accountId: accessLost ? null : accountId,
    context,
    contextKey: viewPreferenceContextKey(context),
    values: accessLost ? getViewPreferenceDefaults(context) : values,
    versions: accessLost
      ? Object.fromEntries(Object.keys(values).map((key) => [key, 0]))
      : versions,
    modified: accessLost ? {} : modified,
    saving: {},
    conflicts: accessLost ? {} : conflicts,
    errors: {},
    accessLost,
  };
}

export function beginViewPreferenceChange(
  state: ViewPreferenceState,
  preferenceKey: string,
  value: ViewPreferenceValue,
): ViewPreferenceState {
  if (
    state.accessLost ||
    !state.accountId ||
    !(preferenceKey in state.values) ||
    state.saving[preferenceKey] ||
    state.conflicts[preferenceKey] ||
    sameValue(state.values[preferenceKey], value)
  ) {
    return state;
  }

  return {
    ...state,
    values: { ...state.values, [preferenceKey]: value },
    modified: { ...state.modified, [preferenceKey]: true },
    saving: { ...state.saving, [preferenceKey]: true },
    errors: omitKey(state.errors, preferenceKey),
  };
}

export function settleViewPreferenceSave(
  state: ViewPreferenceState,
  result: ViewPreferenceSaveResult,
): ViewPreferenceState {
  if (result.status === "unavailable") {
    return createViewPreferenceState(null, state.context, {
      status: "unavailable",
      context_type: state.context.type,
    });
  }

  if (result.status === "error") {
    return {
      ...state,
      saving: omitKey(state.saving, result.preference_key),
      modified: { ...state.modified, [result.preference_key]: true },
      errors: {
        ...state.errors,
        [result.preference_key]: "error",
      },
    };
  }

  if (result.status === "invalid_reference") {
    return {
      ...state,
      saving: omitKey(state.saving, result.preference_key),
      modified: { ...state.modified, [result.preference_key]: true },
      errors: {
        ...state.errors,
        [result.preference_key]: "invalid_reference",
      },
    };
  }

  const preferenceKey = result.preference_key;
  if (!(preferenceKey in state.values)) return state;
  const saving = omitKey(state.saving, preferenceKey);
  const errors = omitKey(state.errors, preferenceKey);
  if (result.status === "saved") {
    return {
      ...state,
      values: { ...state.values, [preferenceKey]: result.value },
      versions: { ...state.versions, [preferenceKey]: result.version },
      modified: omitKey(state.modified, preferenceKey),
      saving,
      errors,
      conflicts: omitKey(state.conflicts, preferenceKey),
    };
  }

  return {
    ...state,
    saving,
    errors,
    conflicts: {
      ...state.conflicts,
      [preferenceKey]: { value: result.value, version: result.version },
    },
    modified: { ...state.modified, [preferenceKey]: true },
  };
}

export function resolveViewPreferenceConflict(
  state: ViewPreferenceState,
  preferenceKey: string,
  resolution: "load-saved" | "keep-local",
):
  | ViewPreferenceState
  | {
      state: ViewPreferenceState;
      command: {
        preference_key: string;
        value: ViewPreferenceValue;
        expected_version: number;
      };
    } {
  const conflict = state.conflicts[preferenceKey];
  if (!conflict) return state;

  if (resolution === "load-saved") {
    return {
      ...state,
      values: { ...state.values, [preferenceKey]: conflict.value },
      versions: { ...state.versions, [preferenceKey]: conflict.version },
      modified: omitKey(state.modified, preferenceKey),
      saving: omitKey(state.saving, preferenceKey),
      conflicts: omitKey(state.conflicts, preferenceKey),
      errors: omitKey(state.errors, preferenceKey),
    };
  }

  const value = state.values[preferenceKey];
  return {
    state: {
      ...state,
      versions: { ...state.versions, [preferenceKey]: conflict.version },
      modified: { ...state.modified, [preferenceKey]: true },
      saving: { ...state.saving, [preferenceKey]: true },
      conflicts: omitKey(state.conflicts, preferenceKey),
      errors: omitKey(state.errors, preferenceKey),
    },
    command: {
      preference_key: preferenceKey,
      value,
      expected_version: conflict.version,
    },
  };
}

export function reconcileViewPreferenceSnapshot(
  state: ViewPreferenceState,
  snapshot: ViewPreferenceSnapshot,
): ViewPreferenceState {
  if (snapshot.status === "unavailable") {
    return createViewPreferenceState(null, state.context, snapshot);
  }
  if (
    (snapshot.context_type && snapshot.context_type !== state.context.type) ||
    (snapshot.board_id !== undefined &&
      snapshot.board_id !== state.context.boardId) ||
    !snapshot.preferences
  ) {
    return state;
  }

  let next = state;
  for (const key of Object.keys(state.values)) {
    const remote = snapshot.preferences[key];
    if (!remote || !Number.isInteger(remote.version) || remote.version < 0) {
      return state;
    }
    const currentVersion = next.versions[key] ?? 0;
    if (remote.version < currentVersion) continue;
    const isLocalDraft = Boolean(next.modified[key] || next.saving[key]);
    if (!isLocalDraft) {
      next = {
        ...next,
        values: { ...next.values, [key]: remote.value },
        versions: { ...next.versions, [key]: remote.version },
        conflicts: omitKey(next.conflicts, key),
        errors: omitKey(next.errors, key),
      };
      continue;
    }

    if (sameValue(next.values[key], remote.value)) {
      next = {
        ...next,
        versions: { ...next.versions, [key]: remote.version },
        modified: omitKey(next.modified, key),
        conflicts: omitKey(next.conflicts, key),
        errors: omitKey(next.errors, key),
      };
      continue;
    }

    if (remote.version > currentVersion) {
      next = {
        ...next,
        conflicts: {
          ...next.conflicts,
          [key]: { value: remote.value, version: remote.version },
        },
      };
    }
  }
  return next;
}

function omitKey<T>(record: Record<string, T>, key: string): Record<string, T> {
  const next = { ...record };
  delete next[key];
  return next;
}
