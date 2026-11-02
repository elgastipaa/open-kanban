import type { SupabaseClient } from "@supabase/supabase-js";
import { ViewPreferenceError } from "@/lib/view-preference-error";
import {
  getViewPreferenceDefaults,
  isValidViewPreferenceContext,
  isValidViewPreferenceValue,
  type ViewPreferenceContext,
  type ViewPreferenceResetResult,
  type ViewPreferenceSaveResult,
  type ViewPreferenceSnapshot,
} from "@/lib/view-preference-state";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isVersion(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0;
}

function preferenceError(error: { code?: string }): ViewPreferenceError {
  if (error.code === "42501") return new ViewPreferenceError("access_denied");
  if (error.code === "22023") return new ViewPreferenceError("invalid");
  return new ViewPreferenceError("uncertain");
}

export async function getMyViewPreferences(
  supabase: SupabaseClient,
  context: ViewPreferenceContext,
): Promise<ViewPreferenceSnapshot> {
  if (!isValidViewPreferenceContext(context)) {
    throw new ViewPreferenceError("invalid");
  }
  const { data, error } = await supabase.rpc("get_my_view_preferences_p", {
    p_context_type: context.type,
    p_board_id: context.boardId,
  });
  if (error) throw preferenceError(error);
  if (!isRecord(data) || typeof data.status !== "string") {
    throw new ViewPreferenceError("uncertain");
  }
  if (data.status === "unavailable") return { status: "unavailable" };
  if (
    data.status !== "available" ||
    data.context_type !== context.type ||
    data.board_id !== context.boardId ||
    !isRecord(data.preferences)
  ) {
    throw new ViewPreferenceError("uncertain");
  }

  const allowedKeys = getViewPreferenceDefaults(context);
  const preferences: NonNullable<ViewPreferenceSnapshot["preferences"]> = {};
  for (const [key, rawPreference] of Object.entries(data.preferences)) {
    if (!(key in allowedKeys) || !isRecord(rawPreference)) {
      throw new ViewPreferenceError("uncertain");
    }
    const value = rawPreference.value;
    const version = rawPreference.version;
    if (
      !isVersion(version) ||
      !isValidViewPreferenceValue(context, key, value)
    ) {
      throw new ViewPreferenceError("uncertain");
    }
    preferences[key] = { value, version };
  }

  for (const key of Object.keys(allowedKeys)) {
    if (!(key in preferences)) throw new ViewPreferenceError("uncertain");
  }

  return {
    status: "available",
    context_type: context.type,
    board_id: context.boardId,
    preferences,
  };
}

export async function saveMyViewPreference(
  supabase: SupabaseClient,
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

  const { data, error } = await supabase.rpc("set_my_view_preference_p", {
    p_context_type: context.type,
    p_board_id: context.boardId,
    p_preference_key: preferenceKey,
    p_value: value,
    p_expected_version: expectedVersion,
  });
  if (error) throw preferenceError(error);
  if (!isRecord(data) || typeof data.status !== "string") {
    throw new ViewPreferenceError("uncertain");
  }

  if (data.status === "unavailable") return { status: "unavailable" };
  if (
    data.status === "invalid_reference" &&
    data.preference_key === preferenceKey
  ) {
    return { status: "invalid_reference", preference_key: preferenceKey };
  }
  if (
    (data.status === "saved" || data.status === "conflict") &&
    data.preference_key === preferenceKey &&
    isVersion(data.version) &&
    isValidViewPreferenceValue(context, preferenceKey, data.value)
  ) {
    return {
      status: data.status,
      preference_key: preferenceKey,
      value: data.value,
      version: data.version,
    };
  }
  throw new ViewPreferenceError("uncertain");
}

export async function resetMyViewPreferences(
  supabase: SupabaseClient,
  context: ViewPreferenceContext,
  expectedVersions: Record<string, number>,
): Promise<ViewPreferenceResetResult> {
  const allowedKeys = getViewPreferenceDefaults(context);
  const keys = Object.keys(allowedKeys);
  if (
    !isValidViewPreferenceContext(context) ||
    Object.keys(expectedVersions).length !== keys.length ||
    keys.some(
      (key) =>
        !Number.isInteger(expectedVersions[key]) || expectedVersions[key] < 0,
    ) ||
    Object.keys(expectedVersions).some((key) => !(key in allowedKeys))
  ) {
    return { status: "error" };
  }

  const { data, error } = await supabase.rpc("reset_my_view_preferences_p", {
    p_context_type: context.type,
    p_board_id: context.boardId,
    p_expected_versions: expectedVersions,
  });
  if (error) throw preferenceError(error);
  if (
    !isRecord(data) ||
    (data.status !== "saved" && data.status !== "conflict")
  ) {
    if (isRecord(data) && data.status === "unavailable") {
      return { status: "unavailable" };
    }
    throw new ViewPreferenceError("uncertain");
  }
  if (
    data.context_type !== context.type ||
    data.board_id !== context.boardId ||
    !isRecord(data.preferences)
  ) {
    throw new ViewPreferenceError("uncertain");
  }

  const preferences: NonNullable<ViewPreferenceSnapshot["preferences"]> = {};
  for (const [key, rawPreference] of Object.entries(data.preferences)) {
    if (!(key in allowedKeys) || !isRecord(rawPreference)) {
      throw new ViewPreferenceError("uncertain");
    }
    if (
      !isVersion(rawPreference.version) ||
      !isValidViewPreferenceValue(context, key, rawPreference.value)
    ) {
      throw new ViewPreferenceError("uncertain");
    }
    preferences[key] = {
      value: rawPreference.value,
      version: rawPreference.version,
    };
  }
  if (keys.some((key) => !(key in preferences))) {
    throw new ViewPreferenceError("uncertain");
  }

  return {
    status: data.status,
    snapshot: {
      status: "available",
      context_type: context.type,
      board_id: context.boardId,
      preferences,
    },
  };
}
