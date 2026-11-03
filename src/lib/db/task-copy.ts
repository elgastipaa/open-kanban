import type { SupabaseClient } from "@supabase/supabase-js";
import type { Priority, Task } from "@/lib/types";

export interface TaskCopyLabel {
  id: string;
  name: string;
  color: string;
}

export interface TaskCopyPreview {
  status: "available" | "unavailable" | "source_changed";
  board_id?: string;
  source_task_id?: string;
  source_column_id?: string;
  target_column_id?: string;
  title?: string;
  description?: string | null;
  priority?: Priority;
  steps?: Array<{ text: string; position: number; is_completed: false }>;
  labels?: TaskCopyLabel[];
  step_count?: number;
  source_hash?: string;
}

export interface TaskCopyCommand {
  operationId: string;
  slug: string;
  sourceTaskId: string;
  targetColumnId: string;
  title: string;
  expectedSourceHash: string;
}

export interface TaskCopyResult {
  status: "confirmed" | "source_changed" | "unavailable" | "expired_unknown";
  operation_id?: string;
  task_id?: string;
  task?: Task;
  title?: string;
  target_column_id?: string;
  source_task_id?: string;
  description?: string | null;
  priority?: Priority;
  steps?: Array<{ text: string; position: number; is_completed: false }>;
  labels?: TaskCopyLabel[];
  source_hash?: string;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function callRpc<T>(
  supabase: SupabaseClient,
  name: string,
  args: Record<string, unknown>,
): Promise<T> {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw error;
  if (!isRecord(data) || typeof data.status !== "string") {
    throw new Error(`Respuesta inválida de ${name}`);
  }
  return data as T;
}

export function previewTaskCopy(
  supabase: SupabaseClient,
  slug: string,
  taskId: string,
) {
  return callRpc<TaskCopyPreview>(supabase, "preview_task_copy_p", {
    p_slug: slug,
    p_task_id: taskId,
  });
}

export function copyTask(supabase: SupabaseClient, command: TaskCopyCommand) {
  return callRpc<TaskCopyResult>(supabase, "copy_task_p", {
    p_operation_id: command.operationId,
    p_slug: command.slug,
    p_source_task_id: command.sourceTaskId,
    p_target_column_id: command.targetColumnId,
    p_title: command.title,
    p_expected_source_hash: command.expectedSourceHash,
  });
}
