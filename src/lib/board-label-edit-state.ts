import type { BoardLabel, BoardLabelColor } from "@/lib/types";

export interface BoardLabelDraft {
  name: string;
  color: BoardLabelColor;
  baseName: string;
  baseColor: BoardLabelColor;
  baseVersion: number;
}

export type BoardLabelDrafts = Record<string, BoardLabelDraft>;

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
