export const TASK_ATTACHMENT_MISSING_MESSAGE =
  "El archivo ya no está disponible. Se ocultó y su limpieza se comprobará de forma segura.";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function isConfirmedMissingTaskAttachmentObject(
  error: unknown,
): boolean {
  return (
    isRecord(error) &&
    error.__isStorageError === true &&
    error.name === "StorageApiError" &&
    error.status === 404
  );
}

export type TaskAttachmentDownloadResponse =
  | { status: "downloaded"; blob: Blob }
  | { status: "missing"; message: string }
  | { status: "failed"; message: string };

export async function readTaskAttachmentDownloadResponse(
  response: Response,
): Promise<TaskAttachmentDownloadResponse> {
  if (response.ok) {
    return { status: "downloaded", blob: await response.blob() };
  }

  const payload: unknown = await response.json().catch(() => null);
  if (
    response.status === 410 &&
    isRecord(payload) &&
    payload.status === "missing"
  ) {
    return {
      status: "missing",
      message: TASK_ATTACHMENT_MISSING_MESSAGE,
    };
  }

  return { status: "failed", message: "No se pudo descargar el archivo." };
}
