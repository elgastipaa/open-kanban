"use server";

import {
  createMySavedView,
  deleteMySavedView,
  listMySavedViews,
  previewMySavedViewRestore,
  restoreMySavedView,
  SavedViewError,
  updateMySavedView,
} from "@/lib/db/saved-views";
import type {
  SavedView,
  SavedViewContext,
  SavedViewDefinition,
  SavedViewMutationResult,
  SavedViewRestorePreview,
  SavedViewsSnapshot,
} from "@/lib/saved-view-state";
import { createClient } from "@/lib/supabase/server";

async function getAuthorizedClient() {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getUser();
  if (error || !data.user) return null;
  return supabase;
}

function isAccessDenied(error: unknown): boolean {
  return error instanceof SavedViewError && error.reason === "access_denied";
}

async function runMutation(
  operation: (
    supabase: NonNullable<Awaited<ReturnType<typeof getAuthorizedClient>>>,
  ) => Promise<SavedViewMutationResult>,
): Promise<SavedViewMutationResult> {
  try {
    const supabase = await getAuthorizedClient();
    if (!supabase) return { status: "unavailable" };
    return await operation(supabase);
  } catch (error) {
    return isAccessDenied(error)
      ? { status: "unavailable" }
      : { status: "error" };
  }
}

export async function loadSavedViews(
  context: SavedViewContext,
): Promise<SavedViewsSnapshot> {
  try {
    const supabase = await getAuthorizedClient();
    if (!supabase) return { status: "unavailable" };
    return await listMySavedViews(supabase, context);
  } catch (error) {
    return isAccessDenied(error)
      ? { status: "unavailable" }
      : { status: "error" };
  }
}

export async function createSavedView(
  context: SavedViewContext,
  name: string,
  definition: SavedViewDefinition,
): Promise<SavedViewMutationResult> {
  return runMutation((supabase) =>
    createMySavedView(supabase, context, name, definition),
  );
}

export async function updateSavedView(
  context: SavedViewContext,
  viewId: string,
  expectedVersion: number,
  name: string,
  definition: SavedViewDefinition,
): Promise<SavedViewMutationResult> {
  return runMutation((supabase) =>
    updateMySavedView(
      supabase,
      context,
      viewId,
      expectedVersion,
      name,
      definition,
    ),
  );
}

export async function deleteSavedView(
  context: SavedViewContext,
  viewId: string,
  expectedVersion: number,
): Promise<SavedViewMutationResult> {
  return runMutation((supabase) =>
    deleteMySavedView(supabase, context, viewId, expectedVersion),
  );
}

export async function previewSavedViewRestore(
  context: SavedViewContext,
  viewId: string,
  name: string,
  definition: SavedViewDefinition,
): Promise<SavedViewRestorePreview> {
  try {
    const supabase = await getAuthorizedClient();
    if (!supabase) return { status: "unavailable" };
    return await previewMySavedViewRestore(
      supabase,
      context,
      viewId,
      name,
      definition,
    );
  } catch (error) {
    return isAccessDenied(error)
      ? { status: "unavailable" }
      : { status: "error" };
  }
}

export async function confirmSavedViewRestore(
  context: SavedViewContext,
  view: Pick<SavedView, "id" | "version">,
  name: string,
  definition: SavedViewDefinition,
): Promise<SavedViewMutationResult> {
  return runMutation((supabase) =>
    restoreMySavedView(supabase, context, view, name, definition),
  );
}
