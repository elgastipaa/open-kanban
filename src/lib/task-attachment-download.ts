export const TASK_ATTACHMENT_MISSING_MESSAGE =
  "El archivo ya no está disponible. Se ocultó y su limpieza se comprobará de forma segura.";
export const TASK_ATTACHMENT_OBJECT_INVENTORY_LIMIT = 2;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function isTaskAttachmentStorageNotFound(error: unknown): boolean {
  return (
    isRecord(error) &&
    error.__isStorageError === true &&
    error.name === "StorageApiError" &&
    error.status === 404
  );
}

function isTaskAttachmentStorageBucketNotFound(error: unknown): boolean {
  return (
    isRecord(error) &&
    (error.statusCode === "NoSuchBucket" ||
      (error.status === 404 && error.message === "Bucket not found"))
  );
}

export function isTaskAttachmentObjectAbsentFromCompleteInventory(
  listedObjects: unknown,
  listError: unknown,
  objectKey: string,
): boolean {
  // Search is substring-based; compare the full key and reject a saturated
  // inventory so a partial result never proves that the object is absent.
  return (
    objectKey.startsWith("attachments/") &&
    listError === null &&
    Array.isArray(listedObjects) &&
    listedObjects.length < TASK_ATTACHMENT_OBJECT_INVENTORY_LIMIT &&
    listedObjects.every(
      (object) => isRecord(object) && typeof object.name === "string",
    ) &&
    !listedObjects.some((object) => `attachments/${object.name}` === objectKey)
  );
}

export function isConfirmedMissingTaskAttachmentObject(
  downloadError: unknown,
  listedObjects: unknown,
  listError: unknown,
  objectKey: string,
): boolean {
  return (
    isTaskAttachmentStorageNotFound(downloadError) &&
    !isTaskAttachmentStorageBucketNotFound(downloadError) &&
    isTaskAttachmentObjectAbsentFromCompleteInventory(
      listedObjects,
      listError,
      objectKey,
    )
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
