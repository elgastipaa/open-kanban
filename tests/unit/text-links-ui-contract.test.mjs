import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { splitSafeTextLinks } from "../../src/lib/text-links.ts";

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

test("the description editor keeps its draft and shows a separate safe-link preview", () => {
  const descriptionStart = taskModal.indexOf(
    '<section aria-labelledby="task-description-heading">',
  );
  const checklistStart = taskModal.indexOf(
    'aria-labelledby="task-checklist-heading"',
    descriptionStart,
  );
  const descriptionSection = taskModal.slice(descriptionStart, checklistStart);
  const editorStart = descriptionSection.indexOf("<textarea");
  const editorEnd = descriptionSection.indexOf("/>", editorStart);
  const previewStart =
    descriptionSection.match(
      /<section\s+aria-labelledby="task-description-preview-heading"/,
    )?.index ?? -1;

  assert.ok(descriptionStart >= 0);
  assert.ok(editorStart >= 0);
  assert.ok(editorEnd > editorStart);
  assert.ok(
    previewStart > editorEnd,
    `Preview should follow the textarea (start ${previewStart}, editor end ${editorEnd})`,
  );
  assert.match(descriptionSection, /id="task-description"/);
  assert.match(descriptionSection, /value=\{draft\.description\}/);
  assert.match(
    descriptionSection,
    /updateDraft\(\{ \.\.\.draft, description: event\.target\.value \}\)/,
  );
  assert.match(
    descriptionSection,
    /<section\s+aria-labelledby="task-description-preview-heading"/,
  );
  assert.match(
    descriptionSection,
    /id="task-description-preview-heading"[^>]*>\s*Vista previa de la descripción\s*</,
  );
  assert.match(
    descriptionSection,
    /<LinkifiedText\s+text=\{draft\.description\}/,
  );

  const previewSegments = splitSafeTextLinks(
    "Guía: https://example.test/manual.",
  );
  assert.ok(
    previewSegments.some(
      (segment) =>
        segment.type === "link" &&
        segment.href === "https://example.test/manual",
    ),
  );
});

test("the task detail exposes a separate title URL control in Spanish", () => {
  assert.match(taskModal, /firstSafeTextLink\(baseTask\.title\)/);
  assert.match(taskModal, /Abrir enlace del título/);
  assert.match(series, /Abrir enlace del título/);
});
