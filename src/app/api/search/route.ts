import { NextResponse } from "next/server";
import { resolveApplicationAccess } from "@/lib/auth";
import { searchUnified } from "@/lib/db/unified-search";
import { createClient } from "@/lib/supabase/server";
import { parseUnifiedSearchRequest } from "@/lib/unified-search-request";

export const dynamic = "force-dynamic";

function json(body: Record<string, unknown>, status = 200): NextResponse {
  return NextResponse.json(body, {
    status,
    headers: { "Cache-Control": "private, no-store, max-age=0" },
  });
}

export async function POST(request: Request): Promise<NextResponse> {
  if (Number(request.headers.get("content-length") ?? 0) > 16_384) {
    return json({ status: "invalid_request" }, 413);
  }

  let body: unknown;
  try {
    const rawBody = await request.text();
    if (new TextEncoder().encode(rawBody).byteLength > 16_384) {
      return json({ status: "invalid_request" }, 413);
    }
    body = JSON.parse(rawBody);
  } catch {
    return json({ status: "invalid_request" }, 400);
  }
  const command = parseUnifiedSearchRequest(body);
  if (!command) return json({ status: "invalid_request" }, 400);

  try {
    const supabase = await createClient();
    const { data: authData, error: authError } = await supabase.auth.getUser();
    if (authError || !authData.user) {
      return json({ status: "unavailable", results: [], has_more: false }, 200);
    }
    const access = await resolveApplicationAccess(supabase);
    if (access.status !== "active") {
      return json({ status: "unavailable", results: [], has_more: false }, 200);
    }
    if (command.filterBoardId || command.labelFilters.length > 0) {
      const { data: boardRows, error: boardsError } =
        await supabase.rpc("list_my_boards");
      if (boardsError || !Array.isArray(boardRows)) {
        throw new Error("No se pudieron comprobar los filtros de búsqueda.");
      }
      const accessibleBoardIds = new Set(
        boardRows.flatMap((board) =>
          typeof board === "object" &&
          board !== null &&
          "id" in board &&
          typeof board.id === "string"
            ? [board.id]
            : [],
        ),
      );
      if (
        (command.filterBoardId &&
          !accessibleBoardIds.has(command.filterBoardId)) ||
        command.labelFilters.some(
          (filter) => !accessibleBoardIds.has(filter.board_id),
        )
      ) {
        return json({
          status: "scope_unavailable",
          results: [],
          has_more: false,
          next_cursor: null,
        });
      }
    }
    return json({ ...(await searchUnified(supabase, command)) });
  } catch {
    return json(
      { status: "error", message: "No se pudo buscar. Inténtalo de nuevo." },
      503,
    );
  }
}
