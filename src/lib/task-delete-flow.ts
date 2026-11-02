export interface TaskDeleteFlow {
  deletingTaskId: string | null;
  waitingForEditorCloseTaskId: string | null;
  resumeEditorTaskId: string | null;
  restoreFocusAfterDialogClose: boolean;
}

export function createTaskDeleteFlow(): TaskDeleteFlow {
  return {
    deletingTaskId: null,
    waitingForEditorCloseTaskId: null,
    resumeEditorTaskId: null,
    restoreFocusAfterDialogClose: false,
  };
}

export function requestCardTaskDelete(
  _flow: TaskDeleteFlow,
  taskId: string,
): TaskDeleteFlow {
  return {
    deletingTaskId: taskId,
    waitingForEditorCloseTaskId: null,
    resumeEditorTaskId: null,
    restoreFocusAfterDialogClose: false,
  };
}

export function requestEditorTaskDelete(
  _flow: TaskDeleteFlow,
  taskId: string,
): TaskDeleteFlow {
  return {
    deletingTaskId: null,
    waitingForEditorCloseTaskId: taskId,
    resumeEditorTaskId: taskId,
    restoreFocusAfterDialogClose: false,
  };
}

export function finishTaskEditorClose(flow: TaskDeleteFlow): TaskDeleteFlow {
  const taskId = flow.waitingForEditorCloseTaskId;
  if (!taskId) return flow;
  return {
    deletingTaskId: taskId,
    waitingForEditorCloseTaskId: null,
    resumeEditorTaskId: flow.resumeEditorTaskId,
    restoreFocusAfterDialogClose: false,
  };
}

export function cancelTaskDelete(
  flow: TaskDeleteFlow,
  taskCanResume: boolean,
): { flow: TaskDeleteFlow; reopenEditorTaskId: string | null } {
  return {
    flow: createTaskDeleteFlow(),
    reopenEditorTaskId: taskCanResume ? flow.resumeEditorTaskId : null,
  };
}

export function confirmTaskDelete(flow: TaskDeleteFlow): TaskDeleteFlow {
  return {
    ...createTaskDeleteFlow(),
    restoreFocusAfterDialogClose: Boolean(
      flow.deletingTaskId && flow.resumeEditorTaskId,
    ),
  };
}

export function finishTaskDeleteDialogClose(flow: TaskDeleteFlow): {
  flow: TaskDeleteFlow;
  restoreTaskFocus: boolean;
} {
  return {
    flow: createTaskDeleteFlow(),
    restoreTaskFocus: flow.restoreFocusAfterDialogClose,
  };
}
