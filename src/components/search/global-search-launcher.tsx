"use client";

import { IconSearch } from "@tabler/icons-react";
import { useRouter } from "next/navigation";
import { useCallback, useEffect } from "react";
import {
  buildUnifiedSearchHref,
  isGlobalSearchShortcut,
} from "@/lib/unified-search-navigation";

export function GlobalSearchLauncher({ enabled }: { enabled: boolean }) {
  const router = useRouter();
  const openSearch = useCallback(() => {
    router.push(
      buildUnifiedSearchHref(
        window.location.pathname,
        new URLSearchParams(window.location.search),
      ),
    );
  }, [router]);

  useEffect(() => {
    if (!enabled) return;
    function handleKeyDown(event: KeyboardEvent) {
      const target = event.target instanceof HTMLElement ? event.target : null;
      if (
        isGlobalSearchShortcut({
          key: event.key,
          ctrlKey: event.ctrlKey,
          metaKey: event.metaKey,
          altKey: event.altKey,
          shiftKey: event.shiftKey,
          targetTag: target?.tagName ?? null,
          targetRole: target
            ?.closest("[role='textbox'], [role='searchbox'], [role='combobox']")
            ?.getAttribute("role"),
          contentEditable: target?.isContentEditable,
        })
      ) {
        event.preventDefault();
        openSearch();
      }
    }
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [enabled, openSearch]);

  if (!enabled) return null;

  return (
    <button
      type="button"
      onClick={openSearch}
      aria-label="Buscar en OpenKanban"
      aria-keyshortcuts="Control+K Meta+K"
      className="fixed right-5 bottom-5 z-40 inline-flex min-h-12 items-center gap-2 rounded-full border border-border bg-surface-overlay px-5 font-medium text-sm text-text-primary shadow-xl transition hover:border-border-hover hover:bg-surface-hover focus-visible:outline-2 focus-visible:outline-focus-ring focus-visible:outline-offset-2"
    >
      <IconSearch aria-hidden="true" size={18} />
      <span>Buscar</span>
      <kbd className="hidden rounded border border-border px-1.5 py-0.5 text-text-secondary text-xs sm:inline">
        Ctrl K
      </kbd>
    </button>
  );
}
