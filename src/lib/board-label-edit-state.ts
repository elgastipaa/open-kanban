import type { BoardLabel, BoardLabelColor } from "@/lib/types";

export interface BoardLabelDraft {
  name: string;
  color: BoardLabelColor;
  baseName: string;
  baseColor: BoardLabelColor;
  baseVersion: number;
}

export type BoardLabelDrafts = Record<string, BoardLabelDraft>;

export interface OrphanedBoardLabelDraft {
  slug: string;
  label: BoardLabel;
  draft: BoardLabelDraft;
}

export type OrphanedBoardLabelDrafts = Record<string, OrphanedBoardLabelDraft>;

export interface BoardLabelCatalogEditorState {
  drafts: BoardLabelDrafts;
  orphanedDrafts: OrphanedBoardLabelDrafts;
}

export function createBoardLabelDraft(label: BoardLabel): BoardLabelDraft {
  return {
    name: label.name,
    color: label.color,
    baseName: label.name,
    baseColor: label.color,
    baseVersion: label.version,
  };
}

export function isBoardLabelDraftDirty(draft: BoardLabelDraft): boolean {
  return draft.name !== draft.baseName || draft.color !== draft.baseColor;
}

export function reconcileBoardLabelDrafts(
  labels: BoardLabel[],
  current: BoardLabelDrafts,
): BoardLabelDrafts {
  return Object.fromEntries(
    labels.map((label) => {
      const draft = current[label.id];
      return [
        label.id,
        draft && isBoardLabelDraftDirty(draft)
          ? draft
          : createBoardLabelDraft(label),
      ];
    }),
  );
}

export function resolveBoardLabelDraftConflict(
  draft: BoardLabelDraft,
  current: BoardLabel,
  resolution: "use_current" | "keep_draft",
): BoardLabelDraft {
  if (resolution === "use_current") return createBoardLabelDraft(current);

  return {
    ...draft,
    baseName: current.name,
    baseColor: current.color,
    baseVersion: current.version,
  };
}

export function reconcileBoardLabelCatalogRead(
  result:
    | {
        status: "available";
        slug: string;
        labels: BoardLabel[];
        previousLabels: BoardLabel[];
        drafts: BoardLabelDrafts;
        orphanedDrafts: OrphanedBoardLabelDrafts;
      }
    | { status: "unavailable" },
): BoardLabelCatalogEditorState {
  if (result.status === "unavailable") {
    return { drafts: {}, orphanedDrafts: {} };
  }

  const activeIds = new Set(result.labels.map((label) => label.id));
  const orphanedDrafts = Object.fromEntries(
    Object.entries(result.orphanedDrafts).filter(
      ([, orphan]) =>
        orphan.slug === result.slug && !activeIds.has(orphan.label.id),
    ),
  );
  const drafts = { ...result.drafts };

  for (const label of result.labels) {
    const recovered = result.orphanedDrafts[label.id];
    if (recovered?.slug === result.slug && !drafts[label.id]) {
      drafts[label.id] = {
        ...recovered.draft,
        baseName: label.name,
        baseColor: label.color,
        baseVersion: label.version,
      };
    }
  }

  for (const [labelId, draft] of Object.entries(result.drafts)) {
    if (activeIds.has(labelId) || !isBoardLabelDraftDirty(draft)) continue;
    const label = result.previousLabels.find((item) => item.id === labelId);
    if (label) {
      orphanedDrafts[labelId] = { slug: result.slug, label, draft };
    } else if (orphanedDrafts[labelId]) {
      orphanedDrafts[labelId] = { ...orphanedDrafts[labelId], draft };
    }
  }

  return {
    drafts: reconcileBoardLabelDrafts(result.labels, drafts),
    orphanedDrafts,
  };
}
