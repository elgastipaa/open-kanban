import type { ReactNode } from "react";
import { splitSafeTextLinks } from "@/lib/text-links";

interface LinkifiedTextProps {
  text: string;
  plainTextLabelFor?: string;
  highlightedRanges?: ReadonlyArray<{
    start: number;
    end: number;
    className: string;
  }>;
}

function renderTextSegment(
  text: string,
  start: number,
  highlightedRanges: LinkifiedTextProps["highlightedRanges"] = [],
  plainTextLabelFor?: string,
): ReactNode[] {
  const end = start + text.length;
  const highlights = highlightedRanges.filter(
    (range) => range.start < end && range.end > start,
  );
  const content: ReactNode[] = [];
  let cursor = start;

  function addPlainText(until: number) {
    if (until <= cursor) return;
    const segment = text.slice(cursor - start, until - start);
    const key = `text-${cursor}`;
    content.push(
      plainTextLabelFor ? (
        <label key={key} htmlFor={plainTextLabelFor}>
          {segment}
        </label>
      ) : (
        <span key={key}>{segment}</span>
      ),
    );
    cursor = until;
  }

  for (const range of highlights) {
    const highlightStart = Math.max(range.start, start);
    const highlightEnd = Math.min(range.end, end);
    addPlainText(highlightStart);
    if (highlightEnd > cursor) {
      content.push(
        <span key={`highlight-${cursor}`} className={range.className}>
          {text.slice(cursor - start, highlightEnd - start)}
        </span>,
      );
      cursor = highlightEnd;
    }
  }

  addPlainText(end);
  return content;
}

export function LinkifiedText({
  text,
  plainTextLabelFor,
  highlightedRanges = [],
}: LinkifiedTextProps) {
  const segments = splitSafeTextLinks(text);
  const content: ReactNode[] = segments.map((segment) => {
    if (segment.type === "text") {
      return (
        <span key={`segment-${segment.start}`}>
          {renderTextSegment(
            segment.text,
            segment.start,
            highlightedRanges,
            plainTextLabelFor,
          )}
        </span>
      );
    }

    return (
      <a
        key={`link-${segment.start}`}
        href={segment.href}
        target="_blank"
        rel="noopener noreferrer"
        referrerPolicy="no-referrer"
        aria-label={`Abrir ${segment.text} en una pestaña nueva`}
        className="pointer-events-auto rounded-sm text-accent underline decoration-current underline-offset-2 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-1"
      >
        {renderTextSegment(segment.text, segment.start, highlightedRanges)}
      </a>
    );
  });

  return <>{content}</>;
}
