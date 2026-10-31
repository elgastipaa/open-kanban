"use client";

import { Droppable } from "@hello-pangea/dnd";
import {
  IconChevronDown,
  IconLayoutSidebarRightCollapse,
} from "@tabler/icons-react";
import { motion } from "motion/react";
import { useState } from "react";
import { AddTask } from "@/components/board/add-task";
import { ColumnHeader } from "@/components/board/column-header";
import { TaskCard } from "@/components/board/task-card";
import { ScrollArea } from "@/components/ui/scroll-area";
import {
  orderTasksByCompletion,
  pendingTaskMoveIndices,
} from "@/lib/task-completion";
import type { ColumnWithTasks, Task } from "@/lib/types";

const columnTransition = {
  type: "spring" as const,
  stiffness: 400,
  damping: 35,
  mass: 0.8,
};

const willChangeTransform = { willChange: "transform" } as const;

interface ColumnProps {
  column: ColumnWithTasks;
  canDelete: boolean;
  canShiftLeft?: boolean;
  canShiftRight?: boolean;
  onRenameColumn: (columnId: string, title: string) => void;
  onToggleCollapse: (columnId: string, is_collapsed: boolean) => void;
  onDeleteColumn: (columnId: string) => void;
  onShiftLeft?: () => void;
  onShiftRight?: () => void;
  onAddTask: (
    columnId: string,
    title: string,
    operationId: string,
    reconcileFirst?: boolean,
  ) => Promise<void>;
  onEditTask: (task: Task, opener: HTMLButtonElement) => void;
  onDeleteTask: (taskId: string) => void;
  onCompleteTask: (task: Task, isCompleted: boolean) => void;
  onMoveTask: (
    sourceColumnId: string,
    destinationColumnId: string,
    sourceIndex: number,
    destinationIndex: number,
  ) => unknown;
}

export function Column({
  column,
  canDelete,
  canShiftLeft,
  canShiftRight,
  onRenameColumn,
  onToggleCollapse,
  onDeleteColumn,
  onShiftLeft,
  onShiftRight,
  onAddTask,
  onEditTask,
  onDeleteTask,
  onCompleteTask,
  onMoveTask,
}: ColumnProps) {
  const [showCompleted, setShowCompleted] = useState(true);
  const [completedExpanded, setCompletedExpanded] = useState(true);
  const { pending, completed } = orderTasksByCompletion(column.tasks);

  if (column.is_collapsed) {
    return (
      <motion.div
        layout
        layoutId={column.id}
        data-column-focus={column.id}
        aria-label={`Columna ${column.title}`}
        tabIndex={-1}
        transition={columnTransition}
        style={willChangeTransform}
      >
        <button
          type="button"
          className="-z-10 flex h-full w-12 min-w-12 shrink-0 cursor-pointer flex-col items-center rounded-xl border-none bg-surface-column-collapsed py-4 text-left transition-colors hover:bg-surface-overlay/50"
          onClick={() => onToggleCollapse(column.id, false)}
          aria-label={`Expand ${column.title} column`}
        >
          <motion.span
            layout="position"
            className="mb-4 shrink-0 cursor-pointer text-text-muted hover:text-text-primary"
          >
            <IconLayoutSidebarRightCollapse size={18} className="rotate-180" />
          </motion.span>
          <motion.div
            layout="position"
            className="flex w-full flex-1 items-start justify-center overflow-hidden py-2"
            style={{ writingMode: "vertical-rl", rotate: 180 }}
          >
            <div className="-translate-x-1.5 overflow-hidden text-ellipsis whitespace-nowrap px-1 font-semibold text-sm text-text-muted">
              {column.title}
            </div>
          </motion.div>
          <motion.span
            layout="position"
            className="mt-4 shrink-0 rounded-full bg-surface-overlay px-2 py-0.5 font-medium text-[10px] text-text-muted"
          >
            {column.tasks.length}
          </motion.span>
        </button>
      </motion.div>
    );
  }

  return (
    <motion.div
      layout
      layoutId={column.id}
      data-column-focus={column.id}
      aria-label={`Columna ${column.title}`}
      tabIndex={-1}
      transition={columnTransition}
      style={willChangeTransform}
      className="z-10 flex h-full w-[calc(280px+0.5rem)] min-w-[280px] shrink-0 flex-col rounded-xl bg-surface-column p-2"
    >
      <motion.div layout="position">
        <ColumnHeader
          title={column.title}
          taskCount={column.tasks.length}
          canDelete={canDelete}
          canShiftLeft={canShiftLeft}
          canShiftRight={canShiftRight}
          onRename={(title) => onRenameColumn(column.id, title)}
          onToggleCollapse={() => onToggleCollapse(column.id, true)}
          onDelete={() => onDeleteColumn(column.id)}
          onShiftLeft={onShiftLeft}
          onShiftRight={onShiftRight}
        />
      </motion.div>

      <ScrollArea className="min-h-0 flex-1 pr-2">
        <Droppable
          droppableId={column.id}
          type="task"
          isDropDisabled={column.is_collapsed}
        >
          {(provided, snapshot) => (
            <div
              ref={provided.innerRef}
              {...provided.droppableProps}
              className={`flex min-h-full flex-col gap-2 rounded-lg p-1 transition-colors ${
                snapshot.isDraggingOver ? "bg-accent-muted" : ""
              }`}
            >
              {pending.map((task, index) => {
                const moveUp = pendingTaskMoveIndices(
                  column.tasks,
                  task.id,
                  index - 1,
                );
                const moveDown = pendingTaskMoveIndices(
                  column.tasks,
                  task.id,
                  index + 1,
                );
                return (
                  <TaskCard
                    key={task.id}
                    task={task}
                    index={index}
                    isCompleted={false}
                    onEdit={onEditTask}
                    onDelete={onDeleteTask}
                    onComplete={onCompleteTask}
                    isFirst={index === 0}
                    isLast={index === pending.length - 1}
                    onMoveUp={() =>
                      moveUp &&
                      onMoveTask(
                        column.id,
                        column.id,
                        moveUp.sourceIndex,
                        moveUp.destinationIndex,
                      )
                    }
                    onMoveDown={() =>
                      moveDown &&
                      onMoveTask(
                        column.id,
                        column.id,
                        moveDown.sourceIndex,
                        moveDown.destinationIndex,
                      )
                    }
                  />
                );
              })}
              {completed.length > 0 && (
                <div className="mt-2 border-border border-t pt-2">
                  <div className="flex items-center justify-between gap-2">
                    {showCompleted ? (
                      <button
                        type="button"
                        className="flex min-h-8 items-center gap-1 rounded-md px-1 text-left font-medium text-text-secondary text-xs hover:text-text-primary"
                        aria-expanded={completedExpanded}
                        onClick={() =>
                          setCompletedExpanded((expanded) => !expanded)
                        }
                      >
                        <IconChevronDown
                          size={14}
                          className={completedExpanded ? "rotate-180" : ""}
                          aria-hidden="true"
                        />
                        Completadas ({completed.length})
                      </button>
                    ) : (
                      <span className="px-1 text-text-muted text-xs">
                        {completed.length} tareas completadas ocultas
                      </span>
                    )}
                    <button
                      type="button"
                      className="rounded-md px-2 py-1 text-text-muted text-xs hover:bg-surface-overlay hover:text-text-primary"
                      onClick={() => {
                        setShowCompleted((visible) => !visible);
                        setCompletedExpanded(true);
                      }}
                    >
                      {showCompleted ? "Ocultar" : "Mostrar"}
                    </button>
                  </div>
                  {showCompleted && completedExpanded && (
                    <div className="mt-2 flex flex-col gap-2">
                      {completed.map((task, index) => (
                        <TaskCard
                          key={task.id}
                          task={task}
                          index={pending.length + index}
                          isCompleted
                          onEdit={onEditTask}
                          onDelete={onDeleteTask}
                          onComplete={onCompleteTask}
                          isFirst
                          isLast
                          onMoveUp={() => undefined}
                          onMoveDown={() => undefined}
                        />
                      ))}
                    </div>
                  )}
                </div>
              )}
              {provided.placeholder}
            </div>
          )}
        </Droppable>

        {/* <ScrollBar className="w-2" /> */}
      </ScrollArea>

      <div className="mt-1 pt-1">
        <AddTask
          columnId={column.id}
          onAdd={(title, operationId, reconcileFirst, targetColumnId) =>
            onAddTask(targetColumnId, title, operationId, reconcileFirst)
          }
        />
      </div>
    </motion.div>
  );
}
