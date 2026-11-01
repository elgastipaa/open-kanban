"use client";

import {
  IconArrowsRightLeft,
  IconCheck,
  IconChevronDown,
  IconChevronUp,
  IconTrash,
} from "@tabler/icons-react";
import { motion } from "motion/react";
import { type MouseEvent, useState } from "react";
import { TaskDueDate } from "@/components/board/task-due-date";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { getTaskChecklistProgress } from "@/lib/task-checklist-state";
import type { ColumnWithTasks, Priority, Task } from "@/lib/types";

interface MobileTaskCardProps {
  task: Task;
  assigneeName: string | null;
  boardToday: string;
  index: number;
  columns: ColumnWithTasks[];
  isFirst: boolean;
  isLast: boolean;
  onEdit: (task: Task, opener: HTMLButtonElement) => void;
  onDelete: (taskId: string) => void;
  onComplete: (task: Task, isCompleted: boolean) => void;
  isCompleted: boolean;
  onMoveToColumn: (taskId: string, targetColumnId: string) => void;
  onMoveUp: (taskId: string) => void;
  onMoveDown: (taskId: string) => void;
}

const priorityConfig: Record<Priority, { label: string; className: string }> = {
  low: { label: "Low", className: "bg-priority-low/15 text-priority-low" },
  medium: {
    label: "Med",
    className: "bg-priority-medium/15 text-priority-medium",
  },
  high: {
    label: "High",
    className: "bg-priority-high/15 text-priority-high",
  },
  urgent: {
    label: "Urgent",
    className: "bg-priority-urgent/15 text-priority-urgent",
  },
};

export function MobileTaskCard({
  task,
  assigneeName,
  boardToday,
  index,
  columns,
  isFirst,
  isLast,
  onEdit,
  onDelete,
  onComplete,
  isCompleted,
  onMoveToColumn,
  onMoveUp,
  onMoveDown,
}: MobileTaskCardProps) {
  const priority = priorityConfig[task.priority];
  const checklistProgress = getTaskChecklistProgress(task.steps);
  const [showMoveMenu, setShowMoveMenu] = useState(false);

  // Columns that are valid move targets (not the current one)
  const otherColumns = columns.filter((col) => col.id !== task.column_id);

  return (
    <motion.div
      layoutId={task.id}
      transition={{
        duration: 0.2,
      }}
      className={`group relative flex flex-col overflow-hidden rounded-lg border border-border bg-surface-raised transition-colors duration-150 hover:border-border-hover ${isCompleted ? "opacity-70" : ""}`}
    >
      {/* Main tappable content area */}
      <button
        type="button"
        data-task-trigger={task.id}
        data-task-column={task.column_id}
        data-task-index={index}
        className="flex min-w-0 flex-1 flex-col p-3 text-left"
        aria-label={`${isCompleted ? "Tarea completada" : "Tarea pendiente"}. Abrir tarea: ${task.title}`}
        onClick={(event: MouseEvent<HTMLButtonElement>) =>
          onEdit(task, event.currentTarget)
        }
      >
        {/* Title */}
        <div className="flex items-start gap-2">
          <span
            className={`mt-0.5 flex size-4 shrink-0 items-center justify-center rounded-[3px] border ${isCompleted ? "border-accent bg-accent text-text-inverse" : "border-text-muted text-transparent"}`}
            aria-hidden="true"
          >
            {isCompleted && <IconCheck size={12} />}
          </span>
          <p className="wrap-break-word pr-2 font-medium text-sm text-text-primary leading-snug">
            {task.title}
          </p>
        </div>
        {task.description && (
          <p className="mt-1 line-clamp-2 text-text-muted text-xs leading-relaxed">
            {task.description}
          </p>
        )}
        {task.assignee_id ? (
          <p className="mt-1 truncate text-text-muted text-xs">
            Responsable: {assigneeName ?? "Responsable no disponible"}
          </p>
        ) : null}

        {/* Footer: priority + date */}
        <div className="mt-2.5 flex items-center justify-between gap-2">
          <span
            className={`inline-flex rounded-full px-2 py-0.5 font-semibold text-[10px] uppercase tracking-wider ${priority.className}`}
          >
            {priority.label}
          </span>
          {checklistProgress.totalCount > 0 ? (
            <span className="mr-2 ml-auto text-[10px] text-text-muted">
              Pasos {checklistProgress.completedCount}/
              {checklistProgress.totalCount}
            </span>
          ) : null}
          {task.due_on ? (
            <TaskDueDate
              dueOn={task.due_on}
              boardToday={boardToday}
              isCompleted={isCompleted}
              compact
            />
          ) : (
            <span className="text-[10px] text-text-muted">
              {new Date(task.created_at).toLocaleDateString("en-US", {
                month: "short",
                day: "numeric",
              })}
            </span>
          )}
        </div>
      </button>

      {/* Bottom action bar - always visible on mobile */}
      <div className="flex items-center border-border border-t px-2 py-1">
        {!isCompleted && (
          <button
            type="button"
            onClick={(event) => {
              event.stopPropagation();
              onComplete(task, true);
            }}
            className="flex items-center gap-1 rounded-md px-1.5 py-1 text-text-muted text-xs transition-colors hover:bg-accent-muted hover:text-text-primary"
            aria-label={`Completar tarea: ${task.title}`}
          >
            <IconCheck size={14} />
            <span>Completar</span>
          </button>
        )}
        {/* Move to column dropdown - only shown when there are other columns */}
        {otherColumns.length > 0 ? (
          <DropdownMenu open={showMoveMenu} onOpenChange={setShowMoveMenu}>
            <DropdownMenuTrigger className="flex items-center gap-1 rounded-md px-1.5 py-1 text-text-muted text-xs transition-colors hover:bg-surface-overlay hover:text-text-secondary">
              <IconArrowsRightLeft size={14} className="opacity-70" />
              <span>Mover a</span>
              <IconChevronDown size={12} />
            </DropdownMenuTrigger>
            <DropdownMenuContent side="top" align="start">
              {otherColumns.map((col) => (
                <DropdownMenuItem
                  key={col.id}
                  onClick={() => {
                    onMoveToColumn(task.id, col.id);
                    setShowMoveMenu(false);
                  }}
                  className="cursor-pointer"
                >
                  <IconCheck
                    size={12}
                    className="invisible mr-1 shrink-0"
                    aria-hidden
                  />
                  <span className="max-w-[160px] truncate">{col.title}</span>
                </DropdownMenuItem>
              ))}
            </DropdownMenuContent>
          </DropdownMenu>
        ) : (
          <span />
        )}

        {/* Spacer pushes right-side controls to the end */}
        <div className="flex-1" />

        {/* Move up / down within column */}
        {!isCompleted && (
          <div className="flex items-center gap-0.5">
            <button
              type="button"
              disabled={isFirst}
              onClick={(e) => {
                e.stopPropagation();
                onMoveUp(task.id);
              }}
              className="flex h-7 w-7 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-surface-overlay hover:text-text-primary disabled:cursor-not-allowed disabled:opacity-30"
              aria-label={`Subir tarea: ${task.title}`}
            >
              <IconChevronUp size={15} stroke={2.5} />
            </button>
            <button
              type="button"
              disabled={isLast}
              onClick={(e) => {
                e.stopPropagation();
                onMoveDown(task.id);
              }}
              className="flex h-7 w-7 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-surface-overlay hover:text-text-primary disabled:cursor-not-allowed disabled:opacity-30"
              aria-label={`Bajar tarea: ${task.title}`}
            >
              <IconChevronDown size={15} stroke={2.5} />
            </button>
          </div>
        )}

        {/* Separator */}
        <div className="mx-1.5 h-4 w-px bg-border-hover/50" />

        {/* Delete button */}
        <button
          type="button"
          onClick={(e) => {
            e.stopPropagation();
            onDelete(task.id);
          }}
          className="flex items-center gap-1 rounded-md px-1.5 py-1 text-text-muted text-xs transition-colors hover:bg-priority-urgent/10 hover:text-priority-urgent"
          aria-label={`Eliminar tarea: ${task.title}`}
        >
          <IconTrash size={13} />
          <span>Eliminar</span>
        </button>
      </div>
    </motion.div>
  );
}
