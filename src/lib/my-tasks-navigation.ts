import type { MyTasksOrder } from "@/lib/types";

export function myTaskBoardHref(
  slug: string,
  taskId: string,
  order: MyTasksOrder,
): string {
  return `/${encodeURIComponent(slug)}?task=${encodeURIComponent(taskId)}&from=my-tasks&order=${order}`;
}

export function myTasksHref(order: MyTasksOrder): string {
  return `/my-tasks?order=${order}`;
}
