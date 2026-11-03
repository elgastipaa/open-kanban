export type ViewPreferenceErrorReason =
  | "access_denied"
  | "invalid"
  | "uncertain";

export class ViewPreferenceError extends Error {
  readonly reason: ViewPreferenceErrorReason;

  constructor(reason: ViewPreferenceErrorReason) {
    super("No se pudo sincronizar la vista personal.");
    this.name = "ViewPreferenceError";
    this.reason = reason;
  }
}

export function isViewPreferenceAccessDenied(
  error: unknown,
): error is ViewPreferenceError {
  return (
    error instanceof ViewPreferenceError && error.reason === "access_denied"
  );
}
