import type { SupabaseClient } from "@supabase/supabase-js";
import {
  type AccessSuspensionPreview,
  type AccessSuspensionResolution,
  type AccessSuspensionResultStatus,
  parseAccessSuspensionPreview,
} from "@/lib/access-suspension-flow";

export type AccessSuspensionErrorReason =
  | "access_denied"
  | "conflict"
  | "last_admin"
  | "uncertain";

export class AccessSuspensionError extends Error {
  constructor(readonly reason: AccessSuspensionErrorReason) {
    super(reason);
    this.name = "AccessSuspensionError";
  }
}

function accessSuspensionError(error: {
  code?: string;
  message?: string;
}): AccessSuspensionError {
  if (error.code === "42501") {
    return new AccessSuspensionError("access_denied");
  }
  if (
    error.code === "23514" &&
    error.message?.includes("At least one active administrator must remain")
  ) {
    return new AccessSuspensionError("last_admin");
  }
  if (["22023", "23514", "40001", "55000"].includes(error.code ?? "")) {
    return new AccessSuspensionError("conflict");
  }
  return new AccessSuspensionError("uncertain");
}

/** Read only the metadata needed to choose safe succession outcomes. */
export async function previewAccountSuspension(
  supabase: SupabaseClient,
  email: string,
): Promise<AccessSuspensionPreview> {
  const { data, error } = await supabase.rpc(
    "admin_preview_account_suspension_p",
    { p_email: email.trim() },
  );
  if (error) throw accessSuspensionError(error);
  const preview = parseAccessSuspensionPreview(data);
  if (!preview) throw new AccessSuspensionError("uncertain");
  return preview;
}

export interface AccessSuspensionResult {
  status: AccessSuspensionResultStatus;
  transferred_boards?: number;
  recoverable_boards?: number;
}

/** Apply the previewed choices atomically; the database revalidates each one. */
export async function suspendAccessWithSuccessions(
  supabase: SupabaseClient,
  email: string,
  resolutions: AccessSuspensionResolution[],
): Promise<AccessSuspensionResult> {
  const { data, error } = await supabase.rpc(
    "admin_suspend_access_with_successions_p",
    { p_email: email.trim(), p_resolutions: resolutions },
  );
  if (error) throw accessSuspensionError(error);
  if (
    typeof data !== "object" ||
    data === null ||
    !("status" in data) ||
    (data.status !== "confirmed" &&
      data.status !== "unavailable" &&
      data.status !== "conflict")
  ) {
    throw new AccessSuspensionError("uncertain");
  }
  if (data.status !== "confirmed") return { status: data.status };
  if (
    !("transferred_boards" in data) ||
    typeof data.transferred_boards !== "number" ||
    !Number.isInteger(data.transferred_boards) ||
    data.transferred_boards < 0 ||
    !("recoverable_boards" in data) ||
    typeof data.recoverable_boards !== "number" ||
    !Number.isInteger(data.recoverable_boards) ||
    data.recoverable_boards < 0
  ) {
    throw new AccessSuspensionError("uncertain");
  }
  return {
    status: "confirmed",
    transferred_boards: data.transferred_boards,
    recoverable_boards: data.recoverable_boards,
  };
}
