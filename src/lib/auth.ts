import type { SupabaseClient } from "@supabase/supabase-js";

export type ApplicationAccessStatus =
  | "signed_out"
  | "google_required"
  | "not_enabled"
  | "suspended"
  | "active"
  | "error";

export interface ApplicationAccess {
  status: ApplicationAccessStatus;
  isAdmin: boolean;
}

export async function resolveApplicationAccess(
  supabase: SupabaseClient,
): Promise<ApplicationAccess> {
  const { data, error } = await supabase.rpc("resolve_application_access");
  if (error || !data || typeof data !== "object") {
    return { status: "error", isAdmin: false };
  }

  const status = data.status as ApplicationAccessStatus;
  if (
    ![
      "signed_out",
      "google_required",
      "not_enabled",
      "suspended",
      "active",
    ].includes(status)
  ) {
    return { status: "error", isAdmin: false };
  }

  return { status, isAdmin: status === "active" && data.is_admin === true };
}

export function getSafeNextPath(value: string | null | undefined): string {
  if (
    !value ||
    !value.startsWith("/") ||
    value.startsWith("//") ||
    value.includes("\\")
  ) {
    return "/";
  }

  try {
    const destination = new URL(value, "https://openkanban.invalid");
    if (
      destination.origin !== "https://openkanban.invalid" ||
      destination.pathname.startsWith("/auth/")
    ) {
      return "/";
    }
    return `${destination.pathname}${destination.search}${destination.hash}`;
  } catch {
    return "/";
  }
}
