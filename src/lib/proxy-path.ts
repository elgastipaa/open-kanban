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

export function boardSlugFromProxyPath(pathname: string): string | null {
  if (
    pathname === "/" ||
    IGNORED_PREFIXES.some((prefix) => pathname.startsWith(prefix)) ||
    pathname === "/invite" ||
    pathname.startsWith("/invite/")
  ) {
    return null;
  }

  return pathname.slice(1);
}
