import { z } from "zod/v4";

export const MAX_LEGACY_BOARD_IMPORT_BYTES = 2 * 1024 * 1024;
const MAX_COLUMNS = 50;
const MAX_TASKS_PER_COLUMN = 500;

const taskSchema = z
  .object({
    title: z.string().trim().min(1).max(200),
    description: z.string().max(2000).nullable(),
    priority: z.enum(["low", "medium", "high", "urgent"]),
    position: z.number().int().nonnegative(),
  })
  .strict();

const columnSchema = z
  .object({
    title: z.string().trim().min(1).max(100),
    position: z.number().int().nonnegative(),
    tasks: z.array(taskSchema).max(MAX_TASKS_PER_COLUMN),
  })
  .strict();

const legacyDocumentSchema = z
  .object({
    version: z.literal(1),
    exportedAt: z.string().min(1).max(100),
    board: z
      .object({
        slug: z.string().min(1).max(100),
        columns: z.array(columnSchema).max(MAX_COLUMNS),
      })
      .strict(),
  })
  .strict();

export type LegacyBoardImport = {
  columns: Array<{
    title: string;
    position: number;
    tasks: Array<{
      title: string;
      description: string | null;
      priority: "low" | "medium" | "high" | "urgent";
      position: number;
    }>;
  }>;
};

export function validateLegacyBoardImportSize(size: number): void {
  if (
    !Number.isSafeInteger(size) ||
    size < 0 ||
    size > MAX_LEGACY_BOARD_IMPORT_BYTES
  ) {
    throw new Error("El archivo supera el límite de 2 MiB.");
  }
}

/**
 * Maps the portable v1 shape to fields the destination can recreate safely.
 * Source slugs never choose the target board and v1 has no verified identities,
 * labels, dates, or series to carry into the current generation.
 */
export function parseLegacyBoardImport(value: unknown): LegacyBoardImport {
  const parsed = legacyDocumentSchema.parse(value);
  return {
    columns: parsed.board.columns.map((column) => ({
      title: column.title,
      position: column.position,
      tasks: column.tasks.map((task) => ({
        title: task.title,
        description: task.description,
        priority: task.priority,
        position: task.position,
      })),
    })),
  };
}
