import type { Metadata } from "next";
import { Bricolage_Grotesque, Inter } from "next/font/google";
import { ThemePreferenceProvider } from "@/components/theme/theme-preference-provider";
import { OfflineBanner } from "@/components/ui/offline-banner";
import { ThemeAwareToaster } from "@/components/ui/theme-aware-toaster";
import { resolveApplicationAccess } from "@/lib/auth";
import { getMyThemePreference } from "@/lib/db/theme-preferences";
import { siteUrl } from "@/lib/site";
import { createClient } from "@/lib/supabase/server";
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

const systemTheme = { theme: "system" as const, version: 0 };

async function loadThemeBootstrap() {
  try {
    const supabase = await createClient();
    const { data: authData, error: authError } = await supabase.auth.getUser();
    if (authError || !authData.user) {
      return { accountId: null, preference: systemTheme, loadFailed: false };
    }

    const access = await resolveApplicationAccess(supabase);
    if (access.status !== "active") {
      return { accountId: null, preference: systemTheme, loadFailed: false };
    }

    try {
      const preference = await getMyThemePreference(supabase);
      return { accountId: authData.user.id, preference, loadFailed: false };
    } catch {
      return {
        accountId: authData.user.id,
        preference: systemTheme,
        loadFailed: true,
      };
    }
  } catch {
    return { accountId: null, preference: systemTheme, loadFailed: false };
  }
}

export default async function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const themeBootstrap = await loadThemeBootstrap();

  return (
    <html lang="es" data-theme={themeBootstrap.preference.theme}>
      <body
        className={`${inter.variable} ${bricolage.variable} bg-surface-base font-sans text-text-primary antialiased`}
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
        <ThemePreferenceProvider
          accountId={themeBootstrap.accountId}
          initialPreference={themeBootstrap.preference}
          loadFailed={themeBootstrap.loadFailed}
        >
          <OfflineBanner />
          {children}
          <ThemeAwareToaster />
        </ThemePreferenceProvider>
      </body>
    </html>
  );
}
