import { z } from "zod/v4";
import { isDateOnly } from "@/lib/task-date";

// ---------------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------------

export const slugSchema = z
  .string()
  .min(1, "Slug is required")
  .regex(
    /^[a-z0-9-]+$/,
    "Slug may only contain lowercase letters, numbers, and dashes",
  );

export const prioritySchema = z.enum(["low", "medium", "high", "urgent"]);

const titleSchema = (label: string, max: number) =>
  z
    .string()
    .trim()
    .min(1, `${label} is required`)
    .max(max, `${label} must be ${max} characters or fewer`);

export const columnTitleSchema = titleSchema("Column title", 100);
export const taskTitleSchema = titleSchema("Task title", 200);
export const taskDescriptionSchema = z
  .string()
  .max(2000, "Description must be 2000 characters or fewer")
  .nullable()
  .optional();
const taskDueOnSchema = z
  .string()
  .refine(isDateOnly, "Escribe una fecha válida.");

// ---------------------------------------------------------------------------
// Payload schemas
// ---------------------------------------------------------------------------

export const boardNameSchema = titleSchema("Board name", 100);
export const createBoardSchema = z.object({
  name: boardNameSchema,
  time_zone: z.string().trim().min(1).max(100),
  operation_id: z.uuid(),
});
export const renameBoardSchema = z.object({ name: boardNameSchema });
export const invitationEmailSchema = z
  .string()
  .trim()
  .min(3)
  .max(254)
  .regex(/^[^\s@]+@[^\s@]+\.[^\s@]+$/);
export const invitationIdSchema = z.uuid();
export const invitationOperationIdSchema = z.uuid();
export const invitationTokenSchema = z.string().regex(/^[0-9a-f]{64}$/);

export const createColumnSchema = z.object({
  board_id: z.string().uuid(),
  title: columnTitleSchema,
  position: z.number().int().nonnegative(),
});

export const updateColumnSchema = z.object({
  id: z.string().uuid(),
  title: columnTitleSchema.optional(),
  position: z.number().int().nonnegative().optional(),
  is_collapsed: z.boolean().optional(),
});

export const createTaskSchema = z.object({
  column_id: z.string().uuid(),
  title: taskTitleSchema,
  description: taskDescriptionSchema,
  priority: prioritySchema.optional(),
});

export const updateTaskSchema = z
  .object({
    id: z.string().uuid(),
    operation_id: z.uuid(),
    updates: z
      .object({
        title: taskTitleSchema.optional(),
        description: taskDescriptionSchema,
        priority: prioritySchema.optional(),
        due_on: taskDueOnSchema.nullable().optional(),
      })
      .strict(),
    expected_versions: z
      .object({
        title: z.number().int().positive().optional(),
        description: z.number().int().positive().optional(),
        priority: z.number().int().positive().optional(),
        due_on: z.number().int().positive().optional(),
      })
      .strict(),
  })
  .strict()
  .superRefine(({ updates, expected_versions }, context) => {
    const updatedFields = Object.keys(updates).sort();
    const versionedFields = Object.keys(expected_versions).sort();
    if (
      updatedFields.length === 0 ||
      updatedFields.length !== versionedFields.length ||
      updatedFields.some((field, index) => field !== versionedFields[index])
    ) {
      context.addIssue({
        code: "custom",
        path: ["expected_versions"],
        message: "Each edited field requires its own current version",
      });
    }
  });
