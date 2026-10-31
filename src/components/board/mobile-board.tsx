"use client";

import { AnimatePresence, motion } from "motion/react";
import { useState } from "react";
import { AddColumnForm } from "@/components/board/add-column";
import { AddTask } from "@/components/board/add-task";
import { MobileColumnControls } from "@/components/board/mobile-column-controls";
import { MobileTaskCard } from "@/components/board/mobile-task-card";
import { useColumnSwipe } from "@/hooks/use-column-swipe";
import {
  orderTasksByCompletion,
  pendingTaskInsertionIndex,
  pendingTaskMoveIndices,
} from "@/lib/task-completion";
import type { ColumnWithTasks, Task } from "@/lib/types";

interface MobileBoardProps {
  columns: ColumnWithTasks[];
  onAddColumn: (title: string) => void;
  onRenameColumn: (columnId: string, title: string) => void;
  onShiftColumn: (fromIndex: number, toIndex: number) => void;
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
    sourceColId: string,
    destColId: string,
    sourceIndex: number,
    destIndex: number,
  ) => void;
  onRequestDeleteColumn: (columnId: string) => void;
}

/** Slide variants - direction is passed via `custom` */
const slideVariants = {
  enter: (dir: number) => ({
    x: dir > 0 ? "100%" : "-100%",
    opacity: 0,
  }),
  center: {
    x: 0,
    opacity: 1,
  },
  exit: (dir: number) => ({
    x: dir > 0 ? "-100%" : "100%",
    opacity: 0,
  }),
};

export function MobileBoard({
  columns,
  onAddColumn,
  onRenameColumn,
  onShiftColumn,
  onAddTask,
  onEditTask,
  onDeleteTask,
  onCompleteTask,
  onMoveTask,
  onRequestDeleteColumn,
}: MobileBoardProps) {
  const [isAddingColumn, setIsAddingColumn] = useState(false);
  const [showCompletedByColumn, setShowCompletedByColumn] = useState<
    Record<string, boolean>
  >({});
  const [completedExpandedByColumn, setCompletedExpandedByColumn] = useState<
    Record<string, boolean>
  >({});
  const { safeIndex, direction, goToPrev, goToNext, goTo, onDragEnd } =
    useColumnSwipe(columns.length);

  const activeColumn = columns[safeIndex];
  const { pending, completed } = activeColumn
    ? orderTasksByCompletion(activeColumn.tasks)
    : { pending: [], completed: [] };
  const showCompleted = activeColumn
    ? showCompletedByColumn[activeColumn.id] !== false
    : true;
  const completedExpanded = activeColumn
    ? completedExpandedByColumn[activeColumn.id] !== false
    : true;

  function handleShiftLeft() {
    if (safeIndex === 0) return;
    onShiftColumn(safeIndex, safeIndex - 1);
    goTo(safeIndex - 1);
  }

  function handleShiftRight() {
    if (safeIndex >= columns.length - 1) return;
    onShiftColumn(safeIndex, safeIndex + 1);
    goTo(safeIndex + 1);
  }

  function handleDeleteColumn() {
    if (!activeColumn) return;
    onRequestDeleteColumn(activeColumn.id);
    // Navigate left if possible after deletion (handled after confirm)
    if (safeIndex > 0) {
      goTo(safeIndex - 1);
    }
  }

  function handleMoveTaskToColumn(taskId: string, targetColumnId: string) {
    if (!activeColumn) return;
    const sourceIndex = activeColumn.tasks.findIndex((t) => t.id === taskId);
    if (sourceIndex === -1) return;

    const targetCol = columns.find((c) => c.id === targetColumnId);
    if (!targetCol) return;

    // Append to the end of the target column
    const destIndex = pendingTaskInsertionIndex(
      targetCol.tasks,
      targetCol.tasks.filter((task) => !task.is_completed).length,
    );
    onMoveTask(activeColumn.id, targetColumnId, sourceIndex, destIndex);
  }

  function handleMovePending(taskId: string, destinationPendingIndex: number) {
    if (!activeColumn) return;
    const indices = pendingTaskMoveIndices(
      activeColumn.tasks,
      taskId,
      destinationPendingIndex,
    );
    if (!indices) return;
    onMoveTask(
      activeColumn.id,
      activeColumn.id,
      indices.sourceIndex,
      indices.destinationIndex,
    );
  }

  return (
    <div className="flex flex-1 flex-col overflow-hidden">
      {/* Sticky header region containing controls and add task */}
      {activeColumn && (
        <div className="flex shrink-0 flex-col">
          <MobileColumnControls
            title={activeColumn.title}
            taskCount={activeColumn.tasks.length}
            currentIndex={safeIndex}
            totalColumns={columns.length}
            canDelete
            canShiftLeft={safeIndex > 0}
            canShiftRight={safeIndex < columns.length - 1}
            onPrev={goToPrev}
            onNext={goToNext}
            onRename={(title) => onRenameColumn(activeColumn.id, title)}
            onShiftLeft={handleShiftLeft}
            onShiftRight={handleShiftRight}
            onDelete={handleDeleteColumn}
            onAddColumn={() => setIsAddingColumn(true)}
          />

          {isAddingColumn ? (
            <div className="mb-3 px-4">
              <AddColumnForm
                onAdd={(title) => {
                  onAddColumn(title);
                  setIsAddingColumn(false);
                }}
                onCancel={() => setIsAddingColumn(false)}
              />
            </div>
          ) : null}

          <div className="mb-3 shrink-0 px-4">
            <AddTask
              columnId={activeColumn.id}
              onAdd={(title, operationId, reconcileFirst, targetColumnId) =>
                onAddTask(targetColumnId, title, operationId, reconcileFirst)
              }
            />
          </div>
        </div>
      )}

      {/* Animated task list - swipe or button navigation */}
      {activeColumn && (
        <div className="relative flex flex-1 overflow-hidden">
          <AnimatePresence initial={false} mode="popLayout" custom={direction}>
            <motion.div
              key={safeIndex}
              custom={direction}
              variants={slideVariants}
              initial="enter"
              animate="center"
              exit="exit"
              transition={{
                x: { type: "spring", stiffness: 300, damping: 30 },
                opacity: { duration: 0.15 },
              }}
              drag="x"
              dragConstraints={{ left: 0, right: 0 }}
              dragElastic={0.15}
              onDragEnd={onDragEnd}
              data-column-focus={activeColumn.id}
              aria-label={`Columna ${activeColumn.title}`}
              tabIndex={-1}
              className="absolute inset-0 flex flex-col overflow-y-auto px-4 pb-4"
            >
              {/* Task cards */}
              <div className="flex flex-col gap-2">
                {activeColumn.tasks.length === 0 ? (
                  <div className="flex flex-col items-center justify-center rounded-xl border border-border border-dashed py-12 text-center">
                    <p className="font-medium text-sm text-text-muted">
                      No tasks yet
                    </p>
                    <p className="mt-1 text-text-muted text-xs">
                      Tap &quot;Add task&quot; above to get started
                    </p>
                  </div>
                ) : (
                  pending.map((task, index) => (
                    <MobileTaskCard
                      key={task.id}
                      task={task}
                      index={index}
                      columns={columns}
                      isCompleted={false}
                      isFirst={index === 0}
                      isLast={index === pending.length - 1}
                      onEdit={onEditTask}
                      onDelete={onDeleteTask}
                      onComplete={onCompleteTask}
                      onMoveToColumn={handleMoveTaskToColumn}
                      onMoveUp={(taskId) =>
                        handleMovePending(taskId, index - 1)
                      }
                      onMoveDown={(taskId) =>
                        handleMovePending(taskId, index + 1)
                      }
                    />
                  ))
                )}
                {completed.length > 0 && (
                  <section className="mt-2 border-border border-t pt-2">
                    <div className="flex items-center justify-between gap-2">
                      {showCompleted ? (
                        <button
                          type="button"
                          className="flex min-h-9 items-center gap-1 rounded-md px-1 text-left font-medium text-sm text-text-secondary hover:text-text-primary"
                          aria-expanded={completedExpanded}
                          onClick={() =>
                            setCompletedExpandedByColumn((current) => ({
                              ...current,
                              [activeColumn.id]: !completedExpanded,
                            }))
                          }
                        >
                          <span aria-hidden="true">
                            {completedExpanded ? "⌄" : "›"}
                          </span>
                          Completadas ({completed.length})
                        </button>
                      ) : (
                        <span className="px-1 text-sm text-text-muted">
                          {completed.length} tareas completadas ocultas
                        </span>
                      )}
                      <button
                        type="button"
                        className="rounded-md px-2 py-2 text-sm text-text-muted hover:bg-surface-overlay hover:text-text-primary"
                        onClick={() => {
                          setShowCompletedByColumn((current) => ({
                            ...current,
                            [activeColumn.id]: !showCompleted,
                          }));
                          setCompletedExpandedByColumn((current) => ({
                            ...current,
                            [activeColumn.id]: true,
                          }));
                        }}
                      >
                        {showCompleted ? "Ocultar" : "Mostrar"}
                      </button>
                    </div>
                    {showCompleted && completedExpanded && (
                      <div className="mt-2 flex flex-col gap-2">
                        {completed.map((task, index) => (
                          <MobileTaskCard
                            key={task.id}
                            task={task}
                            index={pending.length + index}
                            columns={columns}
                            isCompleted
                            isFirst
                            isLast
                            onEdit={onEditTask}
                            onDelete={onDeleteTask}
                            onComplete={onCompleteTask}
                            onMoveToColumn={handleMoveTaskToColumn}
                            onMoveUp={() => undefined}
                            onMoveDown={() => undefined}
                          />
                        ))}
                      </div>
                    )}
                  </section>
                )}
              </div>
            </motion.div>
          </AnimatePresence>
        </div>
      )}
    </div>
  );
}
