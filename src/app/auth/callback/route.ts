import { type NextRequest, NextResponse } from "next/server";
import { getSafeNextPath, resolveApplicationAccess } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export async function GET(request: NextRequest) {
  const url = request.nextUrl;
  const code = url.searchParams.get("code");
  const nextPath = getSafeNextPath(url.searchParams.get("next"));
  const failure = NextResponse.redirect(
    new URL("/login?error=auth", url.origin),
  );
  failure.headers.set("Cache-Control", "private, no-store");
  failure.headers.set("X-Robots-Tag", "noindex, nofollow");

  if (!code) return failure;

  const supabase = await createClient();
  const { error } = await supabase.auth.exchangeCodeForSession(code);
  if (error) return failure;

  const { data: userData, error: userError } = await supabase.auth.getUser();
  if (userError || !userData.user) return failure;

  const access = await resolveApplicationAccess(supabase);
  const destination =
    access.status === "active" ? nextPath : `/?status=${access.status}`;
  const response = NextResponse.redirect(new URL(destination, url.origin));
  response.headers.set("Cache-Control", "private, no-store");
  response.headers.set("X-Robots-Tag", "noindex, nofollow");
  return response;
}
