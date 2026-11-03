export type SafeTextLinkSegment =
  | { type: "text"; text: string; start: number }
  | { type: "link"; text: string; href: string; start: number };

const linkPattern =
  /(?<![\p{L}\p{N}_@:+.-])(?:https?:\/\/|www\.)[^\s<>"'`]+/giu;
const punctuation = new Set([
  ".",
  ",",
  "!",
  "?",
  ";",
  ":",
  "…",
  "。",
  "，",
  "！",
  "？",
  "；",
  "：",
  "”",
  "’",
  "»",
]);
const closingPairs: Record<string, string> = {
  ")": "(",
  "]": "[",
  "}": "{",
};
const openingPairs: Record<string, string> = {
  "(": ")",
  "[": "]",
  "{": "}",
};

function trimOuterPunctuation(candidate: string): string {
  let end = candidate.length;

  while (end > 0) {
    const trailing = candidate[end - 1];
    if (!trailing) break;

    if (punctuation.has(trailing)) {
      end -= 1;
      continue;
    }

    const opening = closingPairs[trailing];
    if (opening) {
      const throughTrailing = candidate.slice(0, end);
      const openings = throughTrailing.split(opening).length - 1;
      const closings = throughTrailing.split(trailing).length - 1;
      if (closings > openings) {
        end -= 1;
        continue;
      }
    }

    const closing = openingPairs[trailing];
    if (closing) {
      const throughTrailing = candidate.slice(0, end);
      const openings = throughTrailing.split(trailing).length - 1;
      const closings = throughTrailing.split(closing).length - 1;
      if (openings > closings) {
        end -= 1;
        continue;
      }
    }

    break;
  }

  return candidate.slice(0, end);
}

function safeHref(candidate: string): string | null {
  const isWww = /^www\./iu.test(candidate);
  const href = isWww ? `https://${candidate}` : candidate;

  if (
    !/^https?:\/\//iu.test(href) ||
    Array.from(href).some((character) => {
      const codePoint = character.codePointAt(0) ?? 0;
      return character === "\\" || codePoint <= 0x1f || codePoint === 0x7f;
    })
  ) {
    return null;
  }

  try {
    const parsed = new URL(href);
    if (
      (parsed.protocol !== "http:" && parsed.protocol !== "https:") ||
      !parsed.hostname ||
      parsed.username ||
      parsed.password
    ) {
      return null;
    }
  } catch {
    return null;
  }

  return href;
}

function pushText(
  segments: SafeTextLinkSegment[],
  text: string,
  start: number,
) {
  if (!text) return;
  const previous = segments[segments.length - 1];
  if (previous?.type === "text") {
    previous.text += text;
  } else {
    segments.push({ type: "text", text, start });
  }
}

export function splitSafeTextLinks(value: string): SafeTextLinkSegment[] {
  const segments: SafeTextLinkSegment[] = [];
  let cursor = 0;

  for (const match of value.matchAll(linkPattern)) {
    const matchedText = match[0];
    const matchIndex = match.index;
    if (matchIndex === undefined || !matchedText) continue;

    const linkText = trimOuterPunctuation(matchedText);
    const href = safeHref(linkText);
    const matchEnd = matchIndex + matchedText.length;

    if (matchIndex > cursor) {
      pushText(segments, value.slice(cursor, matchIndex), cursor);
    }

    if (!href || !linkText) {
      pushText(segments, matchedText, matchIndex);
    } else {
      segments.push({ type: "link", text: linkText, href, start: matchIndex });
      if (linkText.length < matchedText.length) {
        pushText(
          segments,
          matchedText.slice(linkText.length),
          matchIndex + linkText.length,
        );
      }
    }

    cursor = matchEnd;
  }

  if (cursor < value.length) {
    pushText(segments, value.slice(cursor), cursor);
  }

  return segments;
}

export function firstSafeTextLink(value: string): string | null {
  return (
    splitSafeTextLinks(value).find((segment) => segment.type === "link")
      ?.href ?? null
  );
}
