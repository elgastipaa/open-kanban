export const TASK_ATTACHMENT_MISSING_MESSAGE =
  "El archivo ya no está disponible. Se ocultó y su limpieza se comprobará de forma segura.";
export const TASK_ATTACHMENT_OBJECT_INVENTORY_LIMIT = 2;
export const TASK_ATTACHMENT_BUCKET_LOOKUP_TIMEOUT_MS = 5_000;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function isTaskAttachmentStorageObjectNotFound(error: unknown): boolean {
  return (
    isRecord(error) &&
    error.__isStorageError === true &&
    error.name === "StorageApiError" &&
    (error.namespace === undefined || error.namespace === "storage") &&
    error.status === 404 &&
    error.message === "Object not found" &&
    (error.statusCode === "NoSuchKey" || error.statusCode === "404")
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

type TaskAttachmentStorageBucketLookup = {
  getBucket(bucketId: string): Promise<{ data: unknown; error: unknown }>;
};

export async function isConfirmedMissingTaskAttachmentObject(
  downloadError: unknown,
  bucketId: string,
  storage: TaskAttachmentStorageBucketLookup,
): Promise<boolean> {
  if (!isTaskAttachmentStorageObjectNotFound(downloadError)) {
    return false;
  }

  let timeout: ReturnType<typeof setTimeout> | undefined;
  try {
    const lookup = storage.getBucket(bucketId);
    const result = await Promise.race([
      lookup,
      new Promise<never>((_resolve, reject) => {
        timeout = setTimeout(
          () => reject(new Error("Task attachment bucket lookup timed out.")),
          TASK_ATTACHMENT_BUCKET_LOOKUP_TIMEOUT_MS,
        );
      }),
    ]);
    return (
      result.error === null &&
      isRecord(result.data) &&
      result.data.id === bucketId
    );
  } catch {
    return false;
  } finally {
    if (timeout !== undefined) clearTimeout(timeout);
  }
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
