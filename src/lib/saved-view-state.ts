export type SavedViewContext = "search" | "my_tasks";
export type SavedViewScope = "all" | "board" | "my_tasks";
export type SavedViewReferenceField =
  | "boardId"
  | "filterBoardId"
  | "labels"
  | "assigneeId";
export type SavedViewRemovableCondition = Exclude<
  SavedViewReferenceField,
  "boardId"
>;

export interface SavedViewLabelReference {
  boardId: string;
  labelId: string;
}

export interface SavedViewDefinition {
  query: string;
  scope: SavedViewScope;
  boardId: string | null;
  includeCompleted: boolean;
  includeHistory: boolean;
  filterBoardId: string | null;
  dueFilter: "today" | "overdue" | "next_7_days" | "no_date" | null;
  priority: "low" | "medium" | "high" | "urgent" | null;
  assigneeId: string | null;
  unassigned: boolean;
  labels: SavedViewLabelReference[];
  order: "due" | "created";
}

export interface SavedView {
  id: string;
  context_type: SavedViewContext;
  name: string;
  definition: SavedViewDefinition;
  invalid_references: SavedViewReferenceField[];
  version: number;
  needs_review: boolean;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
}

export interface SavedViewsSnapshot {
  status: "available" | "unavailable" | "error";
  context_type?: SavedViewContext;
  active_views?: SavedView[];
  deleted_views?: SavedView[];
}

export type SavedViewMutationResult =
  | { status: "saved" | "restored" | "deleted"; view: SavedView }
  | { status: "conflict"; reason: string; view?: SavedView }
  | { status: "name_conflict" | "limit_reached" | "unavailable" | "expired" }
  | {
      status: "invalid_references";
      invalid_references: SavedViewReferenceField[];
      view?: SavedView;
    }
  | { status: "error" };

export interface SavedViewRestorePreview {
  status: "preview" | "unavailable" | "expired" | "active" | "error";
  can_restore?: boolean;
  reasons?: string[];
  invalid_references?: SavedViewReferenceField[];
  view?: SavedView;
  proposed_name?: string;
  proposed_definition?: SavedViewDefinition;
  active_count?: number;
}

export interface SavedViewConflictDraft {
  localDefinition: SavedViewDefinition;
  current: SavedView;
}

export function detectSavedViewVersionChange(
  currentViews: SavedView[],
  latestViews: SavedView[],
  selectedId: string,
): SavedView | null {
  if (!selectedId) return null;
  const current = currentViews.find((view) => view.id === selectedId);
  const latest = latestViews.find((view) => view.id === selectedId);
  return current && latest && current.version !== latest.version
    ? latest
    : null;
}

export function removeSavedViewCondition(
  definition: SavedViewDefinition,
  field: SavedViewRemovableCondition,
): SavedViewDefinition {
  switch (field) {
    case "filterBoardId":
      return { ...definition, filterBoardId: null };
    case "assigneeId":
      return { ...definition, assigneeId: null, unassigned: false };
    case "labels":
      return { ...definition, labels: [] };
  }
}

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const definitionKeys = [
  "query",
  "scope",
  "boardId",
  "includeCompleted",
  "includeHistory",
  "filterBoardId",
  "dueFilter",
  "priority",
  "assigneeId",
  "unassigned",
  "labels",
  "order",
];

export function isSavedViewContext(value: unknown): value is SavedViewContext {
  return value === "search" || value === "my_tasks";
}

export function isSavedViewDefinition(
  context: SavedViewContext,
  value: unknown,
): value is SavedViewDefinition {
  if (!isRecord(value) || !hasExactKeys(value, definitionKeys)) return false;
  if (
    typeof value.query !== "string" ||
    value.query.length > 200 ||
    (value.scope !== "all" &&
      value.scope !== "board" &&
      value.scope !== "my_tasks") ||
    typeof value.includeCompleted !== "boolean" ||
    typeof value.includeHistory !== "boolean" ||
    typeof value.unassigned !== "boolean" ||
    (value.order !== "due" && value.order !== "created") ||
    !Array.isArray(value.labels) ||
    value.labels.length > 100
  ) {
    return false;
  }

  if (context === "my_tasks") {
    if (
      value.scope !== "my_tasks" ||
      value.query !== "" ||
      value.includeHistory !== false ||
      value.filterBoardId !== null ||
      value.dueFilter !== null ||
      value.priority !== null ||
      value.assigneeId !== null ||
      value.unassigned !== false ||
      value.labels.length !== 0
    ) {
      return false;
    }
  } else if (
    value.scope !== "all" &&
    value.scope !== "board" &&
    value.scope !== "my_tasks"
  ) {
    return false;
  }

  if (
    value.scope === "board" ? !isUuid(value.boardId) : value.boardId !== null
  ) {
    return false;
  }
  if (value.filterBoardId !== null && !isUuid(value.filterBoardId)) {
    return false;
  }
  if (
    value.dueFilter !== null &&
    value.dueFilter !== "today" &&
    value.dueFilter !== "overdue" &&
    value.dueFilter !== "next_7_days" &&
    value.dueFilter !== "no_date"
  ) {
    return false;
  }
  if (
    value.priority !== null &&
    value.priority !== "low" &&
    value.priority !== "medium" &&
    value.priority !== "high" &&
    value.priority !== "urgent"
  ) {
    return false;
  }
  if (value.assigneeId !== null && !isUuid(value.assigneeId)) return false;
  if (value.unassigned && value.assigneeId !== null) return false;

  const seenLabels = new Set<string>();
  for (const label of value.labels) {
    if (
      !isRecord(label) ||
      !hasExactKeys(label, ["boardId", "labelId"]) ||
      !isUuid(label.boardId) ||
      !isUuid(label.labelId)
    ) {
      return false;
    }
    const key = `${label.boardId.toLowerCase()}:${label.labelId.toLowerCase()}`;
    if (seenLabels.has(key)) return false;
    seenLabels.add(key);
  }
  return true;
}

export function resolveSavedViewConflict(
  conflict: SavedViewConflictDraft,
  choice: "use_current" | "keep_local",
): { definition: SavedViewDefinition; expectedVersion: number } {
  return {
    definition:
      choice === "use_current"
        ? conflict.current.definition
        : conflict.localDefinition,
    expectedVersion: conflict.current.version,
  };
}

export function parseSavedViewsSnapshot(
  context: SavedViewContext,
  value: unknown,
): SavedViewsSnapshot {
  if (!isRecord(value) || typeof value.status !== "string") {
    return { status: "error" };
  }
  if (value.status === "unavailable") return { status: "unavailable" };
  if (
    value.status !== "available" ||
    value.context_type !== context ||
    !Array.isArray(value.active_views) ||
    !Array.isArray(value.deleted_views)
  ) {
    return { status: "error" };
  }
  const active = value.active_views.map((item) =>
    parseSavedView(context, item),
  );
  const deleted = value.deleted_views.map((item) =>
    parseSavedView(context, item),
  );
  if (
    active.some((item) => item === null) ||
    deleted.some((item) => item === null)
  ) {
    return { status: "error" };
  }
  if (
    (active as SavedView[]).some((view) => view.deleted_at !== null) ||
    (deleted as SavedView[]).some((view) => view.deleted_at === null)
  ) {
    return { status: "error" };
  }
  return {
    status: "available",
    context_type: context,
    active_views: active as SavedView[],
    deleted_views: deleted as SavedView[],
  };
}

export function parseSavedView(
  context: SavedViewContext,
  value: unknown,
): SavedView | null {
  if (
    !isRecord(value) ||
    !isUuid(value.id) ||
    value.context_type !== context ||
    typeof value.name !== "string" ||
    value.name.length < 1 ||
    value.name.length > 60 ||
    !isSavedViewDefinition(context, value.definition) ||
    (value.invalid_references !== undefined &&
      parseSavedViewReferenceFields(value.invalid_references) === null) ||
    !isVersion(value.version) ||
    typeof value.needs_review !== "boolean" ||
    typeof value.created_at !== "string" ||
    typeof value.updated_at !== "string" ||
    (value.deleted_at !== null && typeof value.deleted_at !== "string")
  ) {
    return null;
  }
  return {
    id: value.id,
    context_type: context,
    name: value.name,
    definition: value.definition,
    invalid_references:
      value.invalid_references === undefined
        ? []
        : (parseSavedViewReferenceFields(value.invalid_references) ?? []),
    version: value.version,
    needs_review: value.needs_review,
    created_at: value.created_at,
    updated_at: value.updated_at,
    deleted_at: value.deleted_at,
  };
}

export function parseSavedViewReferenceFields(
  value: unknown,
): SavedViewReferenceField[] | null {
  if (!Array.isArray(value)) return null;
  const fields: SavedViewReferenceField[] = [];
  for (const item of value) {
    if (!isRecord(item) || !isSavedViewReferenceField(item.field)) return null;
    if (!fields.includes(item.field)) fields.push(item.field);
  }
  return fields;
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && uuidPattern.test(value);
}

function isVersion(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}

function isSavedViewReferenceField(
  value: unknown,
): value is SavedViewReferenceField {
  return (
    value === "boardId" ||
    value === "filterBoardId" ||
    value === "labels" ||
    value === "assigneeId"
  );
}

function hasExactKeys(value: Record<string, unknown>, keys: string[]): boolean {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  return (
    actual.length === expected.length &&
    actual.every((key, index) => key === expected[index])
  );
}
