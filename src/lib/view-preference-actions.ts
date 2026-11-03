"use server";

import {
  getMyViewPreferences,
  resetMyViewPreferences,
  saveMyViewPreference,
} from "@/lib/db/view-preferences";
import { createClient } from "@/lib/supabase/server";
import { isViewPreferenceAccessDenied } from "@/lib/view-preference-error";
import {
  isValidViewPreferenceContext,
  isValidViewPreferenceValue,
  type ViewPreferenceContext,
  type ViewPreferenceResetResult,
  type ViewPreferenceSaveResult,
  type ViewPreferenceSnapshot,
} from "@/lib/view-preference-state";

export async function loadAccountViewPreferences(
  context: ViewPreferenceContext,
): Promise<ViewPreferenceSnapshot> {
  if (!isValidViewPreferenceContext(context)) {
    throw new Error("El contexto de la vista no es válido.");
  }
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getUser();
  if (error || !data.user) return { status: "unavailable" };
  try {
    return await getMyViewPreferences(supabase, context);
  } catch (failure) {
    if (isViewPreferenceAccessDenied(failure)) {
      return { status: "unavailable" };
    }
    throw failure;
  }
}

export async function saveAccountViewPreference(
  context: ViewPreferenceContext,
  preferenceKey: string,
  value: unknown,
  expectedVersion: number,
): Promise<ViewPreferenceSaveResult> {
  if (
    !isValidViewPreferenceContext(context) ||
    !isValidViewPreferenceValue(context, preferenceKey, value) ||
    !Number.isInteger(expectedVersion) ||
    expectedVersion < 0
  ) {
    return { status: "error", preference_key: preferenceKey };
  }
  try {
    const supabase = await createClient();
    const { data, error } = await supabase.auth.getUser();
    if (error || !data.user) return { status: "unavailable" };
    return await saveMyViewPreference(
      supabase,
      context,
      preferenceKey,
      value,
      expectedVersion,
    );
  } catch (error) {
    if (isViewPreferenceAccessDenied(error)) {
      return { status: "unavailable" };
    }
    return { status: "error", preference_key: preferenceKey };
  }
}

export async function resetAccountViewPreferences(
  context: ViewPreferenceContext,
  expectedVersions: Record<string, number>,
): Promise<ViewPreferenceResetResult> {
  if (!isValidViewPreferenceContext(context)) {
    return { status: "error" };
  }
  try {
    const supabase = await createClient();
    const { data, error } = await supabase.auth.getUser();
    if (error || !data.user) return { status: "unavailable" };
    return await resetMyViewPreferences(supabase, context, expectedVersions);
  } catch (error) {
    if (isViewPreferenceAccessDenied(error)) {
      return { status: "unavailable" };
    }
    return { status: "error" };
  }
}
