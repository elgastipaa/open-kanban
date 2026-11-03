import type { BoardLabel, BoardLabelColor } from "@/lib/types";

export interface BoardLabelDraft {
  name: string;
  color: BoardLabelColor;
  baseName: string;
  baseColor: BoardLabelColor;
  baseVersion: number;
}

export type BoardLabelDrafts = Record<string, BoardLabelDraft>;

export interface BoardLabelDraftConflict {
  current: BoardLabel;
  proposal: BoardLabelDraft;
}

export interface OrphanedBoardLabelDraft {
  slug: string;
  label: BoardLabel;
  draft: BoardLabelDraft;
}

export type OrphanedBoardLabelDrafts = Record<string, OrphanedBoardLabelDraft>;

export interface BoardLabelCatalogEditorState {
  drafts: BoardLabelDrafts;
  orphanedDrafts: OrphanedBoardLabelDrafts;
  pendingConflicts: Record<string, BoardLabelDraftConflict>;
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
        labelConflicts?: Record<string, BoardLabelDraftConflict>;
      }
    | { status: "unavailable" },
): BoardLabelCatalogEditorState {
  if (result.status === "unavailable") {
    return { drafts: {}, orphanedDrafts: {}, pendingConflicts: {} };
  }

  const activeIds = new Set(result.labels.map((label) => label.id));
  const pendingConflicts: Record<string, BoardLabelDraftConflict> = {};
  const labelConflicts = result.labelConflicts ?? {};
  const orphanedDrafts = Object.fromEntries(
    Object.entries(result.orphanedDrafts).filter(
      ([, orphan]) =>
        orphan.slug === result.slug && !activeIds.has(orphan.label.id),
    ),
  );
  const drafts = { ...result.drafts };

  for (const label of result.labels) {
    const recovered = result.orphanedDrafts[label.id];
    if (recovered?.slug === result.slug) {
      pendingConflicts[label.id] = {
        current: label,
        proposal:
          drafts[label.id] && isBoardLabelDraftDirty(drafts[label.id])
            ? drafts[label.id]
            : recovered.draft,
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

  for (const [labelId, conflict] of Object.entries(labelConflicts)) {
    if (activeIds.has(labelId)) continue;
    const label =
      result.previousLabels.find((item) => item.id === labelId) ??
      conflict.current;
    orphanedDrafts[labelId] = {
      slug: result.slug,
      label,
      draft: conflict.proposal,
    };
  }

  return {
    drafts: reconcileBoardLabelDrafts(result.labels, drafts),
    orphanedDrafts,
    pendingConflicts,
  };
}
