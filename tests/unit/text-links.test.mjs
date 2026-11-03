import assert from "node:assert/strict";
import { test } from "node:test";
import {
  firstSafeTextLink,
  splitSafeTextLinks,
} from "../../src/lib/text-links.ts";

function outputSegments(text) {
  return splitSafeTextLinks(text).map(({ type, text: segmentText, href }) =>
    type === "link"
      ? { type, text: segmentText, href }
      : { type, text: segmentText },
  );
}

test("recognizes only explicit HTTP, HTTPS, and www URLs", () => {
  const text =
    "HTTP://ejemplo.com/a https://example.org www.example.net ejemplo.com";

  assert.deepEqual(outputSegments(text), [
    {
      type: "link",
      text: "HTTP://ejemplo.com/a",
      href: "HTTP://ejemplo.com/a",
    },
    { type: "text", text: " " },
    {
      type: "link",
      text: "https://example.org",
      href: "https://example.org",
    },
    { type: "text", text: " " },
    {
      type: "link",
      text: "www.example.net",
      href: "https://www.example.net",
    },
    { type: "text", text: " ejemplo.com" },
  ]);
});

test("keeps the original punctuation while excluding only unbalanced closers", () => {
  const text =
    "(https://example.com/a_(b)). www.example.org? https://example.net/x,";
  const segments = splitSafeTextLinks(text);

  assert.deepEqual(outputSegments(text), [
    { type: "text", text: "(" },
    {
      type: "link",
      text: "https://example.com/a_(b)",
      href: "https://example.com/a_(b)",
    },
    { type: "text", text: "). " },
    {
      type: "link",
      text: "www.example.org",
      href: "https://www.example.org",
    },
    { type: "text", text: "? " },
    {
      type: "link",
      text: "https://example.net/x",
      href: "https://example.net/x",
    },
    { type: "text", text: "," },
  ]);
  assert.equal(
    segments.map((segment) => segment.text).join(""),
    text,
    "linkifying must not rewrite or drop the displayed source text",
  );
});

test("preserves accented text and URL paths around a recognized link", () => {
  const text = "Reunión en Peña: https://example.com/café, mañana.";
  const segments = splitSafeTextLinks(text);

  assert.deepEqual(outputSegments(text), [
    { type: "text", text: "Reunión en Peña: " },
    {
      type: "link",
      text: "https://example.com/café",
      href: "https://example.com/café",
    },
    { type: "text", text: ", mañana." },
  ]);
  assert.equal(
    segments.map((segment) => segment.text).join(""),
    text,
    "accented source text stays unchanged in the rendered segments",
  );
});

test("treats only unbalanced trailing brackets as punctuation", () => {
  const text = "https://example.com/a_(b) https://example.org/path(";

  assert.deepEqual(outputSegments(text), [
    {
      type: "link",
      text: "https://example.com/a_(b)",
      href: "https://example.com/a_(b)",
    },
    { type: "text", text: " " },
    {
      type: "link",
      text: "https://example.org/path",
      href: "https://example.org/path",
    },
    { type: "text", text: "(" },
  ]);
});

test("leaves active schemes, local schemes, bare domains, and invalid URLs as text", () => {
  const text =
    "example.com javascript:alert(1) file:///tmp/a data:text/html,hi mailto:user@example.com ftp://example.com javascript:https://evil.example https://user:pass@example.com https://";

  assert.deepEqual(outputSegments(text), [{ type: "text", text }]);
});

test("keeps HTML-like input as text and recognizes only the explicit safe URL", () => {
  const text = "<img src=x onerror=alert(1)> https://example.com";

  assert.deepEqual(outputSegments(text), [
    { type: "text", text: "<img src=x onerror=alert(1)> " },
    {
      type: "link",
      text: "https://example.com",
      href: "https://example.com",
    },
  ]);
});

test("extracts the first safe link for the separate title control", () => {
  assert.equal(
    firstSafeTextLink("ver www.example.com antes"),
    "https://www.example.com",
  );
  assert.equal(firstSafeTextLink("javascript:https://evil.example"), null);
});
