import type { SupabaseClient } from "@supabase/supabase-js";

export async function runAfterCurrentBoardOwnerCheck<T>(
  input: { client: SupabaseClient; actorId: string; slug: string },
  run: () => Promise<T>,
): Promise<
  | { status: "authorized"; value: T }
  | { status: "not_owner" }
  | { status: "unavailable" }
> {
  let data: { id: string } | null;
  try {
    const result = await input.client
      .from("boards")
      .select("id")
      .eq("slug", input.slug)
      .eq("owner_id", input.actorId)
      .maybeSingle();
    if (result.error) return { status: "unavailable" };
    data = result.data;
  } catch {
    return { status: "unavailable" };
  }

  if (!data) return { status: "not_owner" };
  return { status: "authorized", value: await run() };
}
