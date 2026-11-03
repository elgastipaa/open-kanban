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

const IGNORED_EXACT_PATHS = new Set([
  "/account",
  "/apple-icon",
  "/manifest.webmanifest",
  "/offline.v1.html",
  "/sw.js",
]);

export function boardSlugFromProxyPath(pathname: string): string | null {
  if (
    pathname === "/" ||
    IGNORED_EXACT_PATHS.has(pathname) ||
    pathname === "/icons" ||
    pathname.startsWith("/icons/") ||
    IGNORED_PREFIXES.some((prefix) => pathname.startsWith(prefix)) ||
    pathname === "/invite" ||
    pathname.startsWith("/invite/")
  ) {
    return null;
  }

  return pathname.slice(1);
}
