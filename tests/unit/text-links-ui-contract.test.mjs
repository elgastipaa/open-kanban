import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const source = (path) => readFileSync(new URL(path, import.meta.url), "utf8");

const linkifiedText = source("../../src/components/ui/linkified-text.tsx");
const taskCard = source("../../src/components/board/task-card.tsx");
const mobileTaskCard = source(
  "../../src/components/board/mobile-task-card.tsx",
);
const taskModal = source("../../src/components/board/task-modal.tsx");
const conversation = source("../../src/components/board/task-conversation.tsx");
const series = source("../../src/app/series/page.tsx");

test("displayed links use explicit, referrer-free external anchors", () => {
  assert.match(linkifiedText, /target="_blank"/);
  assert.match(linkifiedText, /rel="noopener noreferrer"/);
  assert.match(linkifiedText, /referrerPolicy="no-referrer"/);
  assert.match(linkifiedText, /pointer-events-auto/);
  assert.match(linkifiedText, /focus-visible:ring-2/);
  assert.doesNotMatch(linkifiedText, /\bonClick\s*=|\bonFocus\s*=/);
  assert.doesNotMatch(linkifiedText, /dangerouslySetInnerHTML|\bdownload\s*=/);
});

test("task navigation stays separate from description links on desktop and mobile", () => {
  for (const card of [taskCard, mobileTaskCard]) {
    assert.match(card, /data-task-trigger=\{task\.id\}/);
    assert.match(card, /onEdit\(task, event\.currentTarget\)/);
    assert.match(
      card,
      /className="absolute inset-0 z-0 cursor-pointer outline-none"/,
    );
    assert.match(card, /pointer-events-none relative z-10/);
    assert.match(card, /<LinkifiedText text=\{task\.description\}/);
  }
});

test("comments preserve mention segments while displaying links as text links", () => {
  assert.match(conversation, /taskCommentTextSegments\(comment\)/);
  assert.match(
    conversation,
    /segments\.map\(\(segment\) => segment\.text\)\.join\(""\)/,
  );
  assert.match(conversation, /segment\.isCurrentMember/);
  assert.match(
    conversation,
    /<LinkifiedText text=\{text\} highlightedRanges=\{highlightedRanges\}/,
  );
  assert.match(linkifiedText, /highlightedRanges\?: ReadonlyArray/);
});

test("steps and historical descriptions and comments use the text renderer", () => {
  assert.match(taskModal, /<LinkifiedText\s+text=\{step\.text\}/);
  assert.match(
    series,
    /<LinkifiedText\s+text=\{selectedOccurrence\.task\.description\}/,
  );
  assert.match(
    series,
    /<LinkifiedText\s+text=\{\s*comment\.deleted[\s\S]*?comment\.content\s*\?\?[\s\S]*?Este comentario ya no tiene contenido disponible\./,
  );
});

test("the task detail exposes a separate title URL control in Spanish", () => {
  assert.match(taskModal, /firstSafeTextLink\(baseTask\.title\)/);
  assert.match(taskModal, /Abrir enlace del título/);
  assert.match(series, /Abrir enlace del título/);
});
