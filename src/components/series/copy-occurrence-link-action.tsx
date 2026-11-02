"use client";

import { useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { copyLinkToClipboard } from "@/lib/copy-link-clipboard";

interface CopyOccurrenceLinkActionProps {
  href: string;
}

export function CopyOccurrenceLinkAction({
  href,
}: CopyOccurrenceLinkActionProps) {
  const [message, setMessage] = useState("");
  const [fallbackUrl, setFallbackUrl] = useState<string | null>(null);
  const [isCopying, setIsCopying] = useState(false);
  const fallbackInputRef = useRef<HTMLInputElement>(null);

  async function copyLink() {
    const absoluteUrl = new URL(href, window.location.origin).toString();
    setIsCopying(true);
    const copied = await copyLinkToClipboard(absoluteUrl, (text) =>
      navigator.clipboard.writeText(text),
    );
    if (copied) {
      setFallbackUrl(null);
      setMessage("Enlace copiado.");
    } else {
      setFallbackUrl(absoluteUrl);
      setMessage(
        "No se pudo copiar. Selecciona el enlace y cópialo manualmente.",
      );
    }
    setIsCopying(false);
  }

  function selectFallbackLink() {
    fallbackInputRef.current?.focus();
    fallbackInputRef.current?.select();
  }

  return (
    <div className="mt-3 space-y-2">
      <Button
        type="button"
        variant="ghost"
        size="sm"
        onClick={() => void copyLink()}
        disabled={isCopying}
      >
        Copiar enlace
      </Button>
      {message ? (
        <p
          aria-live="polite"
          className={
            fallbackUrl
              ? "text-priority-medium text-xs"
              : "text-text-muted text-xs"
          }
        >
          {message}
        </p>
      ) : null}
      {fallbackUrl ? (
        <div className="space-y-2">
          <label
            className="block font-medium text-text-secondary text-xs"
            htmlFor="occurrence-link-fallback"
          >
            Enlace privado a esta ocurrencia
          </label>
          <input
            ref={fallbackInputRef}
            id="occurrence-link-fallback"
            readOnly
            value={fallbackUrl}
            onFocus={(event) => event.currentTarget.select()}
            className="min-h-10 w-full rounded-lg border border-border bg-surface-base px-3 text-xs"
          />
          <Button
            type="button"
            variant="ghost"
            size="sm"
            onClick={selectFallbackLink}
          >
            Seleccionar enlace
          </Button>
        </div>
      ) : null}
    </div>
  );
}
