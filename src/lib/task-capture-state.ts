import type { TaskCaptureErrorReason } from "./db/tasks";

export interface TaskCaptureFailureState {
  title: string;
  errorReason: TaskCaptureErrorReason;
  removeComposer: boolean;
}

export function taskCaptureErrorReasonFromCode(
  code: string,
): TaskCaptureErrorReason | null {
  switch (code) {
    case "42501":
      return "access_denied";
    case "23514":
      return "conflict";
    case "22023":
      return "rejected";
    default:
      return null;
  }
}

export function taskCaptureFailureTransition(
  title: string,
  errorReason: TaskCaptureErrorReason,
): TaskCaptureFailureState {
  const removeComposer = errorReason === "access_denied";
  return {
    title: removeComposer ? "" : title,
    errorReason,
    removeComposer,
  };
}
