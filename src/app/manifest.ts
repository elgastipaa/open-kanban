import type { MetadataRoute } from "next";

export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "OpenKanban",
    short_name: "OpenKanban",
    description: "Acceso privado a tus tableros de OpenKanban.",
    start_url: "/",
    scope: "/",
    display: "standalone",
    background_color: "#111514",
    theme_color: "#dfff00",
    icons: [
      {
        src: "/icons/open-kanban-192.v1.svg",
        sizes: "192x192",
        type: "image/svg+xml",
      },
      {
        src: "/icons/open-kanban-512.v1.svg",
        sizes: "512x512",
        type: "image/svg+xml",
      },
    ],
  };
}
