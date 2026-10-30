import type { Metadata } from "next";
import { Bricolage_Grotesque, Inter } from "next/font/google";
import { Toaster } from "sonner";
import { OfflineBanner } from "@/components/ui/offline-banner";
import { siteUrl } from "@/lib/site";
import "./globals.css";

const inter = Inter({
  variable: "--font-inter",
  subsets: ["latin"],
  display: "swap",
});

const bricolage = Bricolage_Grotesque({
  variable: "--font-bricolage",
  subsets: ["latin"],
  display: "swap",
});

export const metadata: Metadata = {
  metadataBase: siteUrl,
  title: {
    default: "OpenKanban - Tableros privados",
    template: "%s | OpenKanban",
  },
  description: "Acceso privado a tus tableros de OpenKanban.",
  alternates: {
    canonical: "/",
  },
  keywords: [
    "kanban",
    "project management",
    "realtime",
    "board",
    "private kanban",
    "closed kanban",
    "productivity utility",
    "open source kanban",
  ],
  openGraph: {
    title: "OpenKanban - Tableros privados",
    description: "Acceso privado a tus tableros de OpenKanban.",
    url: "/",
    siteName: "OpenKanban",
    locale: "es",
    type: "website",
    images: [
      {
        url: "/og.png",
        width: 1200,
        height: 630,
        alt: "OpenKanban - tableros privados",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "OpenKanban - Tableros privados",
    description: "Acceso privado a tus tableros de OpenKanban.",
    images: ["/og.png"],
  },
  robots: {
    index: false,
    follow: false,
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="es" className="dark">
      <body
        className={`${inter.variable} ${bricolage.variable} bg-black font-sans text-white antialiased`}
      >
        <script
          type="application/ld+json"
          // biome-ignore lint/security/noDangerouslySetInnerHtml: Required for JSON-LD schema injectiontant
          dangerouslySetInnerHTML={{
            __html: JSON.stringify({
              "@context": "https://schema.org",
              "@type": "SoftwareApplication",
              name: "OpenKanban",
              description: "Acceso privado a tus tableros de OpenKanban.",
              applicationCategory: "ProductivityApplication",
              operatingSystem: "Any",
              offers: {
                "@type": "Offer",
                price: "0",
                priceCurrency: "USD",
              },
            }),
          }}
        />
        <OfflineBanner />
        {children}
        <Toaster
          theme="dark"
          position="bottom-right"
          toastOptions={{
            style: {
              background: "#111",
              border: "1px solid #1a1a1a",
              color: "#fff",
            },
          }}
          visibleToasts={5}
          richColors
        />
      </body>
    </html>
  );
}
