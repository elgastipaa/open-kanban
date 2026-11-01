"use client";

import { Draggable } from "@hello-pangea/dnd";
import {
  IconCheck,
  IconChevronDown,
  IconChevronUp,
  IconGripVertical,
  IconTrash,
} from "@tabler/icons-react";
import type { MouseEvent } from "react";
import { createPortal } from "react-dom";
import { TaskDueDate } from "@/components/board/task-due-date";
import type { Priority, Task } from "@/lib/types";

interface TaskCardProps {
  task: Task;
  boardToday: string;
  index: number;
  onEdit: (task: Task, opener: HTMLButtonElement) => void;
  onDelete: (taskId: string) => void;
  onComplete: (task: Task, isCompleted: boolean) => void;
  isCompleted: boolean;
  isFirst: boolean;
  isLast: boolean;
  onMoveUp: () => void;
  onMoveDown: () => void;
}

const priorityConfig: Record<Priority, { label: string; className: string }> = {
  low: { label: "Low", className: "bg-priority-low/15 text-priority-low" },
  medium: {
    label: "Med",
    className: "bg-priority-medium/15 text-priority-medium",
  },
  high: { label: "High", className: "bg-priority-high/15 text-priority-high" },
  urgent: {
    label: "Urgent",
    className: "bg-priority-urgent/15 text-priority-urgent",
  },
};

export function TaskCard({
  task,
  boardToday,
  index,
  onEdit,
  onDelete,
  onComplete,
  isCompleted,
  isFirst,
  isLast,
  onMoveUp,
  onMoveDown,
}: TaskCardProps) {
  const priority = priorityConfig[task.priority];

  return (
    <Draggable
      draggableId={task.id}
      index={index}
      key={task.id}
      isDragDisabled={isCompleted}
    >
      {(provided, snapshot) => {
        const child = (
          <div
            ref={provided.innerRef}
            {...provided.draggableProps}
            style={{
              ...provided.draggableProps.style,
              ...(snapshot.isDragging && { zIndex: 9999 }),
            }}
            className={`group relative flex cursor-pointer overflow-hidden rounded-lg border bg-surface-raised outline-none transition-colors duration-150 has-focus-visible:ring-1 has-focus-visible:ring-accent ${
              snapshot.isDragging
                ? "scale-[1.02] border-accent/40 shadow-accent/5 shadow-lg"
                : "border-border hover:border-border-hover"
            } ${isCompleted ? "opacity-70" : ""}`}
          >
            {/* Drag handle - distinctly separated on the left */}
            {isCompleted ? (
              <span className="flex w-10 shrink-0 items-center justify-center border-border border-r bg-surface-base/40 sm:w-8" />
            ) : (
              <button
                type="button"
                {...provided.dragHandleProps}
                aria-label={`Mover tarea: ${task.title}. Pulsa la barra espaciadora para moverla.`}
                className="flex w-10 shrink-0 cursor-grab items-center justify-center border-border border-r bg-surface-base/40 text-text-muted outline-0 transition-colors hover:bg-surface-hover hover:text-text-secondary active:cursor-grabbing sm:w-8"
              >
                <IconGripVertical size={16} />
              </button>
            )}

            {/* Main detail trigger */}
            <button
              type="button"
              data-task-trigger={task.id}
              data-task-column={task.column_id}
              data-task-index={index}
              aria-label={`${isCompleted ? "Tarea completada" : "Tarea pendiente"}. Abrir tarea: ${task.title}`}
              className="flex min-w-0 flex-1 flex-col p-3 pl-3.5 text-left outline-none focus-visible:ring-1 focus-visible:ring-accent"
              onClick={(event: MouseEvent<HTMLButtonElement>) =>
                onEdit(task, event.currentTarget)
              }
            >
              {/* Header / Text */}
              <div className="flex items-start gap-2 pr-6">
                <span
                  className={`mt-0.5 flex size-4 shrink-0 items-center justify-center rounded-[3px] border ${isCompleted ? "border-accent bg-accent text-text-inverse" : "border-text-muted text-transparent"}`}
                  aria-hidden="true"
                  title={isCompleted ? "Completada" : "Pendiente"}
                >
                  {isCompleted && <IconCheck size={12} />}
                </span>
                <div className="min-w-0">
                  <p className="wrap-break-word font-medium text-sm text-text-primary leading-snug">
                    {task.title}
                  </p>
                  {task.description && (
                    <p className="mt-1 line-clamp-2 text-text-muted text-xs leading-relaxed">
                      {task.description}
                    </p>
                  )}
                </div>
              </div>

              {/* Footer: priority + date */}
              <div className="mt-2.5 flex items-center justify-between gap-2">
                <span
                  className={`inline-flex rounded-full px-2 py-0.5 font-semibold text-[10px] uppercase tracking-wider ${priority.className}`}
                >
                  {priority.label}
                </span>
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

            <div className="flex items-center justify-end gap-1 border-border border-t px-2 py-1">
              {!isCompleted && (
                <button
                  type="button"
                  onClick={(event) => {
                    event.stopPropagation();
                    onComplete(task, true);
                  }}
                  className="mr-auto flex h-8 items-center gap-1 rounded-md px-2 text-text-muted text-xs transition-colors hover:bg-accent-muted hover:text-text-primary"
                  aria-label={`Completar tarea: ${task.title}`}
                >
                  <IconCheck size={15} />
                  Completar
                </button>
              )}
              {isCompleted ? null : (
                <>
                  <button
                    type="button"
                    disabled={isFirst}
                    onClick={(event) => {
                      event.stopPropagation();
                      onMoveUp();
                    }}
                    className="flex h-8 w-8 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-surface-overlay hover:text-text-primary disabled:cursor-not-allowed disabled:opacity-30"
                    aria-label={`Subir tarea: ${task.title}`}
                  >
                    <IconChevronUp size={16} />
                  </button>
                  <button
                    type="button"
                    disabled={isLast}
                    onClick={(event) => {
                      event.stopPropagation();
                      onMoveDown();
                    }}
                    className="flex h-8 w-8 items-center justify-center rounded-md text-text-muted transition-colors hover:bg-surface-overlay hover:text-text-primary disabled:cursor-not-allowed disabled:opacity-30"
                    aria-label={`Bajar tarea: ${task.title}`}
                  >
                    <IconChevronDown size={16} />
                  </button>
                </>
              )}
            </div>

            {/* Delete button is a sibling of the detail trigger, never nested inside it. */}
            <button
              type="button"
              aria-label={`Eliminar tarea: ${task.title}`}
              onClick={() => onDelete(task.id)}
              className="absolute top-1.5 right-1.5 cursor-pointer rounded-md p-1.5 text-text-muted opacity-0 transition-colors hover:bg-red-500/10 hover:text-red-400 focus:opacity-100 focus:outline-none focus-visible:ring-1 focus-visible:ring-accent group-hover:opacity-100"
            >
              <IconTrash size={14} />
            </button>
          </div>
        );

        if (snapshot.isDragging) {
          return createPortal(child, document.body);
        }

        return child;
      }}
    </Draggable>
  );
}
