import type { MetadataRoute } from "next";
import { siteUrl } from "@/lib/site";

export default function robots(): MetadataRoute.Robots {
  const baseUrl = siteUrl.origin;

  return {
    rules: {
      userAgent: "*",
      allow: [
        "/$",
        "/privacy$",
        "/terms$",
        "/_next/",
        "/favicon.ico",
        "/opengraph-image",
        "/twitter-image",
      ],
      disallow: ["/"],
    },
    sitemap: `${baseUrl}/sitemap.xml`,
  };
}
