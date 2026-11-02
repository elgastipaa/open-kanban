import type { SupabaseClient } from "@supabase/supabase-js";
import {
  isRecord,
  isSavedViewContext,
  isSavedViewDefinition,
  parseSavedView,
  parseSavedViewReferenceFields,
  parseSavedViewsSnapshot,
  type SavedView,
  type SavedViewContext,
  type SavedViewDefinition,
  type SavedViewMutationResult,
  type SavedViewRestorePreview,
  type SavedViewsSnapshot,
} from "@/lib/saved-view-state";

export type SavedViewErrorReason = "access_denied" | "invalid" | "uncertain";

export class SavedViewError extends Error {
  constructor(readonly reason: SavedViewErrorReason) {
    super("No se pudo sincronizar la vista guardada.");
    this.name = "SavedViewError";
  }
}

function rpcErrorReason(error: { code?: string }): SavedViewErrorReason {
  if (error.code === "42501") return "access_denied";
  if (error.code === "22023") return "invalid";
  return "uncertain";
}

async function callRpc(
  supabase: SupabaseClient,
  name: string,
  args: Record<string, unknown>,
): Promise<unknown> {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw new SavedViewError(rpcErrorReason(error));
  return data;
}

function parseMutationResult(
  context: SavedViewContext,
  value: unknown,
): SavedViewMutationResult {
  if (!isRecord(value) || typeof value.status !== "string") {
    return { status: "error" };
  }
  if (
    value.status === "saved" ||
    value.status === "restored" ||
    value.status === "deleted"
  ) {
    const view = parseSavedView(context, value.view);
    return view ? { status: value.status, view } : { status: "error" };
  }
  if (value.status === "conflict" && typeof value.reason === "string") {
    let view: SavedView | undefined;
    if (value.view !== undefined) {
      const parsedView = parseSavedView(context, value.view);
      if (!parsedView) return { status: "error" };
      view = parsedView;
    }
    return { status: "conflict", reason: value.reason, view };
  }
  if (value.status === "invalid_references") {
    const references = parseSavedViewReferenceFields(value.invalid_references);
    if (!references) return { status: "error" };
    let view: SavedView | undefined;
    if (value.view !== undefined) {
      const parsedView = parseSavedView(context, value.view);
      if (!parsedView) return { status: "error" };
      view = parsedView;
    }
    return {
      status: "invalid_references",
      invalid_references: references,
      view,
    };
  }
  if (
    value.status === "name_conflict" ||
    value.status === "limit_reached" ||
    value.status === "unavailable" ||
    value.status === "expired"
  ) {
    return { status: value.status };
  }
  return { status: "error" };
}

async function mutate(
  supabase: SupabaseClient,
  name: string,
  args: Record<string, unknown>,
  context: SavedViewContext,
): Promise<SavedViewMutationResult> {
  return parseMutationResult(context, await callRpc(supabase, name, args));
}

export async function listMySavedViews(
  supabase: SupabaseClient,
  context: SavedViewContext,
): Promise<SavedViewsSnapshot> {
  if (!isSavedViewContext(context)) throw new SavedViewError("invalid");
  const value = await callRpc(supabase, "list_my_saved_views_p", {
    p_context_type: context,
  });
  const snapshot = parseSavedViewsSnapshot(context, value);
  if (snapshot.status === "error") throw new SavedViewError("uncertain");
  return snapshot;
}

export function createMySavedView(
  supabase: SupabaseClient,
  context: SavedViewContext,
  name: string,
  definition: SavedViewDefinition,
): Promise<SavedViewMutationResult> {
  if (
    !isSavedViewContext(context) ||
    !isSavedViewDefinition(context, definition)
  ) {
    throw new SavedViewError("invalid");
  }
  return mutate(
    supabase,
    "create_my_saved_view_p",
    { p_context_type: context, p_name: name, p_definition: definition },
    context,
  );
}

export function updateMySavedView(
  supabase: SupabaseClient,
  context: SavedViewContext,
  viewId: string,
  expectedVersion: number,
  name: string,
  definition: SavedViewDefinition,
): Promise<SavedViewMutationResult> {
  if (
    !isSavedViewContext(context) ||
    !isSavedViewDefinition(context, definition) ||
    !Number.isSafeInteger(expectedVersion) ||
    expectedVersion < 1
  ) {
    throw new SavedViewError("invalid");
  }
  return mutate(
    supabase,
    "update_my_saved_view_p",
    {
      p_view_id: viewId,
      p_expected_version: expectedVersion,
      p_name: name,
      p_definition: definition,
    },
    context,
  );
}

export function deleteMySavedView(
  supabase: SupabaseClient,
  context: SavedViewContext,
  viewId: string,
  expectedVersion: number,
): Promise<SavedViewMutationResult> {
  if (
    !isSavedViewContext(context) ||
    !Number.isSafeInteger(expectedVersion) ||
    expectedVersion < 1
  ) {
    throw new SavedViewError("invalid");
  }
  return mutate(
    supabase,
    "delete_my_saved_view_p",
    { p_view_id: viewId, p_expected_version: expectedVersion },
    context,
  );
}

export async function previewMySavedViewRestore(
  supabase: SupabaseClient,
  context: SavedViewContext,
  viewId: string,
  name: string,
  definition: SavedViewDefinition,
): Promise<SavedViewRestorePreview> {
  if (
    !isSavedViewContext(context) ||
    !isSavedViewDefinition(context, definition)
  ) {
    throw new SavedViewError("invalid");
  }
  const value = await callRpc(supabase, "preview_restore_my_saved_view_p", {
    p_context_type: context,
    p_view_id: viewId,
    p_name: name,
    p_definition: definition,
  });
  if (!isRecord(value) || typeof value.status !== "string") {
    throw new SavedViewError("uncertain");
  }
  if (
    value.status === "unavailable" ||
    value.status === "expired" ||
    value.status === "active"
  ) {
    return { status: value.status };
  }
  if (value.status !== "preview") throw new SavedViewError("uncertain");
  const view = parseSavedView(context, value.view);
  const invalidReferences = parseSavedViewReferenceFields(
    value.invalid_references,
  );
  if (
    !view ||
    !invalidReferences ||
    typeof value.can_restore !== "boolean" ||
    !Array.isArray(value.reasons) ||
    !value.reasons.every((reason) => typeof reason === "string") ||
    value.proposed_name !== name ||
    !isSavedViewDefinition(context, value.proposed_definition) ||
    typeof value.active_count !== "number"
  ) {
    throw new SavedViewError("uncertain");
  }
  return {
    status: "preview",
    can_restore: value.can_restore,
    reasons: value.reasons,
    invalid_references: invalidReferences,
    view,
    proposed_name: name,
    proposed_definition: value.proposed_definition,
    active_count: value.active_count,
  };
}

export function restoreMySavedView(
  supabase: SupabaseClient,
  context: SavedViewContext,
  view: Pick<SavedView, "id" | "version">,
  name: string,
  definition: SavedViewDefinition,
): Promise<SavedViewMutationResult> {
  if (
    !isSavedViewContext(context) ||
    !isSavedViewDefinition(context, definition)
  ) {
    throw new SavedViewError("invalid");
  }
  return mutate(
    supabase,
    "restore_my_saved_view_p",
    {
      p_context_type: context,
      p_view_id: view.id,
      p_expected_version: view.version,
      p_name: name,
      p_definition: definition,
    },
    context,
  );
}
