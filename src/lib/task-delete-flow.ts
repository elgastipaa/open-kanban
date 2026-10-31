export interface TaskDeleteFlow {
  deletingTaskId: string | null;
  waitingForEditorCloseTaskId: string | null;
  resumeEditorTaskId: string | null;
}

export function createTaskDeleteFlow(): TaskDeleteFlow {
  return {
    deletingTaskId: null,
    waitingForEditorCloseTaskId: null,
    resumeEditorTaskId: null,
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
  };
}

export function finishTaskEditorClose(flow: TaskDeleteFlow): TaskDeleteFlow {
  const taskId = flow.waitingForEditorCloseTaskId;
  if (!taskId) return flow;
  return {
    deletingTaskId: taskId,
    waitingForEditorCloseTaskId: null,
    resumeEditorTaskId: flow.resumeEditorTaskId,
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

export function confirmTaskDelete(_flow: TaskDeleteFlow): TaskDeleteFlow {
  return createTaskDeleteFlow();
}
