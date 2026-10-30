import { createServerClient } from "@supabase/ssr";
import { type NextRequest, NextResponse } from "next/server";
import { getBoardVisitLimiter } from "@/lib/ratelimit";

const IGNORED_PREFIXES = [
  "/_next",
  "/api",
  "/favicon.ico",
  "/og.png",
  "/OpenKanban-Logo.png",
  "/rate-limit",
  "/privacy",
  "/terms",
  "/robots.txt",
  "/sitemap.xml",
  "/login",
  "/auth",
  "/admin",
];

function sanitizeSlug(raw: string): string {
  let decoded = raw;
  try {
    decoded = decodeURIComponent(raw);
  } catch {
    decoded = raw.replace(/(%[0-9A-Fa-f]{2})+/g, (match) => {
      try {
        return decodeURIComponent(match);
      } catch {
        return match;
      }
    });
  }

  return decoded
    .toLowerCase()
    .replace(/[\s_]/g, "-")
    .replace(/[?!@#$%^&*()+=_[\]{};':",./<>/]/g, "-")
    .replace(/[^a-z0-9-]/g, "-")
    .replace(/-{2,}/g, "-")
    .replace(/^-+|-+$/g, "");
}

function addPrivateHeaders(response: NextResponse): NextResponse {
  response.headers.set("Cache-Control", "private, no-store, max-age=0");
  response.headers.set("Pragma", "no-cache");
  response.headers.set("X-Robots-Tag", "noindex, nofollow");
  return response;
}

async function refreshSession(request: NextRequest) {
  let response = NextResponse.next({ request });
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_PUBLIC_URL;
  const supabaseKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  if (!supabaseUrl || !supabaseKey) return response;

  const supabase = createServerClient(supabaseUrl, supabaseKey, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet) {
        for (const { name, value } of cookiesToSet) {
          request.cookies.set(name, value);
        }
        response = NextResponse.next({ request });
        for (const { name, value, options } of cookiesToSet) {
          response.cookies.set(name, value, options);
        }
      },
    },
  });

  await supabase.auth.getClaims();
  return response;
}

export async function proxy(request: NextRequest) {
  const { pathname } = request.nextUrl;

  if (
    pathname !== "/" &&
    !IGNORED_PREFIXES.some((prefix) => pathname.startsWith(prefix))
  ) {
    const slug = pathname.slice(1);
    const sanitized = sanitizeSlug(slug);
    if (!sanitized) {
      return addPrivateHeaders(
        NextResponse.redirect(new URL("/", request.url)),
      );
    }
    if (slug !== sanitized) {
      const url = request.nextUrl.clone();
      url.pathname = `/${sanitized}`;
      return addPrivateHeaders(NextResponse.redirect(url, 308));
    }

    const limiter = getBoardVisitLimiter();
    if (limiter) {
      const ip =
        request.headers.get("x-real-ip") ??
        request.headers.get("x-forwarded-for")?.split(",").pop()?.trim() ??
        "anonymous";
      const { success } = await limiter.limit(ip);
      if (!success) {
        return addPrivateHeaders(
          NextResponse.redirect(new URL("/rate-limit", request.url)),
        );
      }
    }
  }

  return addPrivateHeaders(await refreshSession(request));
}

export const config = {
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|sitemap.xml|robots.txt|og.png|OpenKanban-Logo.png).*)",
  ],
};
