/** Public instance URL, shared by metadata and the landing's URL prefix. */
export const siteUrl = new URL(
  process.env.NEXT_PUBLIC_SITE_URL || "http://localhost:3000",
);
