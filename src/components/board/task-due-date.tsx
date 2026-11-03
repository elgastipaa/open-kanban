import { IconCalendar } from "@tabler/icons-react";
import { taskDueDateLabel } from "@/lib/task-date";

interface TaskDueDateProps {
  dueOn: string | null;
  boardToday: string;
  isCompleted: boolean;
  compact?: boolean;
}

export function TaskDueDate({
  dueOn,
  boardToday,
  isCompleted,
  compact = false,
}: TaskDueDateProps) {
  const label = taskDueDateLabel(dueOn, boardToday, isCompleted);
  if (!label) return null;

  const overdue = label.startsWith("Vencida");
  return (
    <span
      className={`inline-flex min-w-0 items-center gap-1 ${compact ? "text-[10px]" : "text-xs"} ${overdue ? "text-priority-urgent" : "text-text-muted"}`}
    >
      <IconCalendar size={compact ? 12 : 14} aria-hidden="true" />
      <span className="truncate">{label}</span>
    </span>
  );
}
