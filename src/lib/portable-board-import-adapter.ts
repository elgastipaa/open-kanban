import { createHash } from "node:crypto";
import type {
  PortableBoardImportAdapter,
  PortableBoardImportObjectTarget,
  PortableBoardImportPreview,
} from "./portable-board-import";

const STORAGE_BUCKET = "task-attachments";
const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const SOURCE_REF = /^attachment_[0-9a-f]{64}$/u;
const SHA256 = /^[0-9a-f]{64}$/u;

interface RpcResult {
  data: unknown;
  error: unknown;
}

interface RpcClient {
  rpc(name: string, args: Record<string, unknown>): PromiseLike<RpcResult>;
}

interface StorageBucket {
  upload(
    path: string,
    bytes: Uint8Array,
    options: { contentType: string; upsert: boolean },
  ): Promise<{ error: unknown }>;
  download(path: string): Promise<{ data: Blob | null; error: unknown }>;
  remove(paths: string[]): Promise<{ error: unknown }>;
}

interface StorageClient extends RpcClient {
  storage: { from(bucket: string): StorageBucket };
}

export class PortableBoardImportAdapterError extends Error {
  readonly kind:
    | "invalid"
    | "conflict"
    | "capacity"
    | "unavailable"
    | "storage";

  constructor(
    message: string,
    kind: "invalid" | "conflict" | "capacity" | "unavailable" | "storage",
  ) {
    super(message);
    this.kind = kind;
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function rpcError(message: string, error: unknown): never {
  throw new PortableBoardImportAdapterError(
    message,
    error ? "unavailable" : "invalid",
  );
}

async function callRpc(
  client: RpcClient,
  name: string,
  args: Record<string, unknown>,
  message: string,
): Promise<unknown> {
  let response: RpcResult;
  try {
    response = await client.rpc(name, args);
  } catch {
    throw new PortableBoardImportAdapterError(message, "unavailable");
  }
  if (response.error) rpcError(message, response.error);
  return response.data;
}

function parseObjectTarget(value: unknown): PortableBoardImportObjectTarget {
  const row = asRecord(value);
  if (
    !row ||
    typeof row.source_ref !== "string" ||
    !SOURCE_REF.test(row.source_ref) ||
    typeof row.attachment_id !== "string" ||
    !UUID.test(row.attachment_id) ||
    typeof row.file_name !== "string" ||
    row.file_name.length < 1 ||
    row.file_name.length > 120 ||
    typeof row.size_bytes !== "number" ||
    !Number.isSafeInteger(row.size_bytes) ||
    row.size_bytes < 1 ||
    row.size_bytes > 24_000 ||
    typeof row.sha256 !== "string" ||
    !SHA256.test(row.sha256) ||
    typeof row.object_key !== "string" ||
    row.object_key !== `attachments/${row.attachment_id}` ||
    typeof row.uploaded !== "boolean"
  ) {
    throw new PortableBoardImportAdapterError(
      "El destino de un adjunto no coincide con la reserva del servidor.",
      "invalid",
    );
  }
  return row as unknown as PortableBoardImportObjectTarget;
}

function importStatus(value: unknown): string | null {
  const row = asRecord(value);
  return typeof row?.status === "string" ? row.status : null;
}

export function createPortableBoardImportAdapter(input: {
  client: RpcClient;
  storage: StorageClient | (() => StorageClient);
  actorId: string;
  slug: string;
}): PortableBoardImportAdapter {
  const getStorage = (): StorageClient =>
    typeof input.storage === "function" ? input.storage() : input.storage;

  return {
    async start({ operationId, sourceSha256, manifest }) {
      const data = await callRpc(
        input.client,
        "prepare_board_import_v2_p",
        {
          p_slug: input.slug,
          p_operation_id: operationId,
          p_source_sha256: sourceSha256,
          p_manifest: manifest,
        },
        "No se pudo iniciar la preparación del respaldo.",
      );
      const status = importStatus(data);
      if (status === "staging") return { status: "staging" };
      if (status === "prepared" || status === "confirmed") {
        return {
          status,
          preview: data as PortableBoardImportPreview,
        };
      }
      if (status === "conflict") {
        throw new PortableBoardImportAdapterError(
          "La operación de importación ya pertenece a otro contenido.",
          "conflict",
        );
      }
      throw new PortableBoardImportAdapterError(
        "El tablero no está disponible para importar el respaldo.",
        "unavailable",
      );
    },

    async stage({ operationId, entity, batchIndex, records }) {
      const data = await callRpc(
        input.client,
        "stage_board_import_v2_batch_p",
        {
          p_slug: input.slug,
          p_operation_id: operationId,
          p_entity: entity,
          p_batch_index: batchIndex,
          p_records: records,
        },
        "No se pudo guardar una parte del respaldo.",
      );
      const status = importStatus(data);
      if (status === "staging") return;
      if (status === "conflict") {
        throw new PortableBoardImportAdapterError(
          "La preparación cambió durante la carga del respaldo.",
          "conflict",
        );
      }
      throw new PortableBoardImportAdapterError(
        "Una parte del respaldo supera los límites permitidos.",
        "invalid",
      );
    },

    async reserve({ operationId }) {
      const data = await callRpc(
        input.client,
        "reserve_board_import_v2_p",
        { p_slug: input.slug, p_operation_id: operationId },
        "No se pudieron preparar las reservas del respaldo.",
      );
      const row = asRecord(data);
      if (row?.status === "capacity") {
        throw new PortableBoardImportAdapterError(
          "No hay capacidad suficiente para conservar el contenido anterior y preparar los nuevos adjuntos.",
          "capacity",
        );
      }
      if (row?.status !== "reserved" || !Array.isArray(row.targets)) {
        throw new PortableBoardImportAdapterError(
          "No se pudieron preparar las reservas del respaldo.",
          "unavailable",
        );
      }
      return { targets: row.targets.map(parseObjectTarget) };
    },

    async upload({ operationId, target, bytes }) {
      if (
        bytes.byteLength !== target.size_bytes ||
        createHash("sha256").update(bytes).digest("hex") !== target.sha256 ||
        target.object_key !== `attachments/${target.attachment_id}`
      ) {
        throw new PortableBoardImportAdapterError(
          "El adjunto no coincide con su reserva de tamaño y hash.",
          "invalid",
        );
      }
      let uploadResult: { error: unknown };
      try {
        const storage = getStorage();
        uploadResult = await storage.storage
          .from(STORAGE_BUCKET)
          .upload(target.object_key, bytes, {
            contentType: "text/plain",
            upsert: true,
          });
      } catch {
        throw new PortableBoardImportAdapterError(
          "No se pudo almacenar un adjunto del respaldo.",
          "storage",
        );
      }
      if (uploadResult.error) {
        throw new PortableBoardImportAdapterError(
          "No se pudo almacenar un adjunto del respaldo.",
          "storage",
        );
      }

      let downloaded: { data: Blob | null; error: unknown };
      try {
        const storage = getStorage();
        downloaded = await storage.storage
          .from(STORAGE_BUCKET)
          .download(target.object_key);
      } catch {
        throw new PortableBoardImportAdapterError(
          "No se pudo verificar el adjunto almacenado.",
          "storage",
        );
      }
      if (downloaded.error || !downloaded.data) {
        throw new PortableBoardImportAdapterError(
          "No se pudo verificar el adjunto almacenado.",
          "storage",
        );
      }
      const storedBytes = new Uint8Array(await downloaded.data.arrayBuffer());
      if (
        storedBytes.byteLength !== target.size_bytes ||
        createHash("sha256").update(storedBytes).digest("hex") !== target.sha256
      ) {
        throw new PortableBoardImportAdapterError(
          "El adjunto almacenado no coincide con su tamaño o hash.",
          "storage",
        );
      }

      const result = await callRpc(
        getStorage(),
        "mark_board_import_v2_object_uploaded_p",
        {
          p_actor_id: input.actorId,
          p_operation_id: operationId,
          p_attachment_id: target.attachment_id,
          p_verified_size_bytes: target.size_bytes,
          p_verified_sha256: target.sha256,
        },
        "No se pudo confirmar la reserva del adjunto.",
      );
      if (importStatus(result) !== "uploaded") {
        throw new PortableBoardImportAdapterError(
          "No se pudo confirmar la reserva del adjunto.",
          "storage",
        );
      }
    },

    async finalize({ operationId }) {
      const data = await callRpc(
        input.client,
        "finalize_board_import_v2_p",
        { p_slug: input.slug, p_operation_id: operationId },
        "No se pudo finalizar la preparación del respaldo.",
      );
      if (importStatus(data) !== "prepared") {
        throw new PortableBoardImportAdapterError(
          "No se pudo finalizar la preparación del respaldo.",
          "unavailable",
        );
      }
      return data as PortableBoardImportPreview;
    },

    async cancel({ operationId }) {
      const data = await callRpc(
        input.client,
        "cancel_board_import_v2_p",
        { p_slug: input.slug, p_operation_id: operationId },
        "No se pudo cancelar la preparación del respaldo.",
      );
      const row = asRecord(data);
      if (row?.status !== "cancelled" || !Array.isArray(row.objects)) return;
      const cleanTargets = row.objects.flatMap((item) => {
        const target = asRecord(item);
        return target &&
          typeof target.attachment_id === "string" &&
          UUID.test(target.attachment_id) &&
          typeof target.object_key === "string" &&
          target.object_key === `attachments/${target.attachment_id}`
          ? [
              {
                attachmentId: target.attachment_id,
                objectKey: target.object_key,
              },
            ]
          : [];
      });
      for (const target of cleanTargets) {
        try {
          const storage = getStorage();
          const result = await storage.storage
            .from(STORAGE_BUCKET)
            .remove([target.objectKey]);
          if (result.error) continue;
          await callRpc(
            storage,
            "complete_board_import_v2_object_cleanup_p",
            {
              p_actor_id: input.actorId,
              p_operation_id: operationId,
              p_attachment_id: target.attachmentId,
            },
            "No se pudo confirmar la limpieza del adjunto.",
          );
        } catch {
          // Keep cleanup_pending metadata and quota charged until Storage ACKs.
        }
      }
    },
  };
}
