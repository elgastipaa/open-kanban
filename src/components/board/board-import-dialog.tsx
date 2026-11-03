"use client";

import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Modal } from "@/components/ui/modal";
import { MAX_LEGACY_BOARD_IMPORT_BYTES } from "@/lib/legacy-board-import";
import {
  MAX_PORTABLE_BOARD_IMPORT_BYTES,
  MAX_PORTABLE_BOARD_IMPORT_DECISION_BYTES,
} from "@/lib/portable-board-import-limits";

interface GenerationSummary {
  columns: number;
  tasks: number;
  comments: number;
  labels: number;
  birthdays: number;
  series: number;
  attachments: number;
  attachment_bytes: number;
}

interface CapacitySnapshot {
  limit_bytes: number;
  used_bytes: number;
  available_bytes: number;
  can_replace: boolean;
}

interface ImportPreview {
  status: "prepared" | "label_conflict" | "member_conflict";
  operation_id: string;
  content_revision: number;
  source_sha256?: string;
  expires_at: string;
  source_version: 1 | 2;
  current: GenerationSummary;
  imported?: GenerationSummary;
  capacity: CapacitySnapshot;
  member_refs: string[];
  member_mappings: Array<{
    source_ref: string;
    target_user_id: string | null;
  }>;
  members: Array<{ user_id: string; name: string }>;
  label_renames: Array<{
    source_ref: string;
    name: string;
    imported_name: string;
  }>;
  label_conflicts: LabelConflict[];
}

interface LabelConflict {
  source_ref: string;
  name: string;
  conflict_name: string;
}

interface PendingPreparation {
  operationId: string;
  fileName: string;
  fileSize: number;
  fileLastModified: number;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function count(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
    ? value
    : null;
}

function parseSummary(value: unknown): GenerationSummary | null {
  const row = asRecord(value);
  if (!row) return null;
  const columns = count(row.columns);
  const tasks = count(row.tasks);
  const comments = count(row.comments);
  const labels = count(row.labels);
  const birthdays = count(row.birthdays);
  const series = count(row.series);
  const attachments = count(row.attachments);
  const attachmentBytes = count(row.attachment_bytes);
  if (
    columns === null ||
    tasks === null ||
    comments === null ||
    labels === null ||
    birthdays === null ||
    series === null ||
    attachments === null ||
    attachmentBytes === null
  ) {
    return null;
  }
  return {
    columns,
    tasks,
    comments,
    labels,
    birthdays,
    series,
    attachments,
    attachment_bytes: attachmentBytes,
  };
}

function parseCapacity(value: unknown): CapacitySnapshot | null {
  const row = asRecord(value);
  if (!row) return null;
  const limit = count(row.limit_bytes);
  const used = count(row.used_bytes);
  const available = count(row.available_bytes);
  if (
    limit === null ||
    used === null ||
    available === null ||
    typeof row.can_replace !== "boolean"
  ) {
    return null;
  }
  return {
    limit_bytes: limit,
    used_bytes: used,
    available_bytes: available,
    can_replace: row.can_replace,
  };
}

function parsePreview(value: unknown): ImportPreview | null {
  const row = asRecord(value);
  if (
    !row ||
    (row.status !== "prepared" &&
      row.status !== "label_conflict" &&
      row.status !== "member_conflict") ||
    typeof row.operation_id !== "string" ||
    typeof row.expires_at !== "string"
  ) {
    return null;
  }
  const revision = count(row.content_revision);
  const current = parseSummary(row.current);
  const imported =
    row.imported === undefined ? undefined : parseSummary(row.imported);
  const capacity = parseCapacity(row.capacity);
  const memberRefs = Array.isArray(row.member_refs) ? row.member_refs : [];
  const members = Array.isArray(row.members) ? row.members : [];
  const memberMappings = Array.isArray(row.member_mappings)
    ? row.member_mappings
    : [];
  const labelRenames = Array.isArray(row.label_renames)
    ? row.label_renames
    : [];
  const labelConflicts =
    row.status === "label_conflict"
      ? parseLabelConflicts(row.label_conflicts)
      : [];
  const sourceVersion =
    row.source_version === undefined ? 1 : row.source_version;
  if (
    revision === null ||
    !current ||
    !capacity ||
    (sourceVersion !== 1 && sourceVersion !== 2) ||
    (row.imported !== undefined && !imported) ||
    !memberRefs.every(
      (reference) =>
        typeof reference === "string" &&
        /^member_[0-9a-f]{64}$/u.test(reference),
    ) ||
    !members.every((value) => {
      const member = asRecord(value);
      return (
        member !== null &&
        typeof member.user_id === "string" &&
        typeof member.name === "string" &&
        member.name.length > 0
      );
    }) ||
    !memberMappings.every((value) => {
      const mapping = asRecord(value);
      return (
        mapping !== null &&
        typeof mapping.source_ref === "string" &&
        /^member_[0-9a-f]{64}$/u.test(mapping.source_ref) &&
        (mapping.target_user_id === null ||
          (typeof mapping.target_user_id === "string" &&
            /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(
              mapping.target_user_id,
            )))
      );
    }) ||
    !labelRenames.every((value) => {
      const rename = asRecord(value);
      return (
        rename !== null &&
        typeof rename.source_ref === "string" &&
        /^label_[0-9a-f]{64}$/u.test(rename.source_ref) &&
        typeof rename.name === "string" &&
        typeof rename.imported_name === "string"
      );
    }) ||
    labelConflicts === null
  ) {
    return null;
  }
  return {
    operation_id: row.operation_id,
    content_revision: revision,
    source_sha256:
      typeof row.source_sha256 === "string" ? row.source_sha256 : undefined,
    expires_at: row.expires_at,
    source_version: sourceVersion,
    current,
    imported: imported ?? undefined,
    capacity,
    status: row.status,
    member_refs: memberRefs as string[],
    member_mappings: memberMappings as Array<{
      source_ref: string;
      target_user_id: string | null;
    }>,
    members: members as Array<{ user_id: string; name: string }>,
    label_renames: labelRenames as Array<{
      source_ref: string;
      name: string;
      imported_name: string;
    }>,
    label_conflicts: labelConflicts ?? [],
  };
}

function parseLabelConflicts(value: unknown): LabelConflict[] | null {
  if (!Array.isArray(value)) return null;
  const conflicts: LabelConflict[] = [];
  for (const entry of value) {
    const row = asRecord(entry);
    if (
      !row ||
      typeof row.source_ref !== "string" ||
      !/^label_[0-9a-f]{64}$/u.test(row.source_ref) ||
      typeof row.name !== "string" ||
      row.name.length < 1 ||
      row.name.length > 40 ||
      typeof row.conflict_name !== "string" ||
      row.conflict_name.length < 1 ||
      row.conflict_name.length > 40
    ) {
      return null;
    }
    conflicts.push({
      source_ref: row.source_ref,
      name: row.name,
      conflict_name: row.conflict_name,
    });
  }
  return conflicts;
}

function describeError(body: unknown, fallback: string): string {
  const row = asRecord(body);
  if (row?.status === "conflict") {
    return "El tablero cambió desde la vista previa. Vuelve a preparar la operación y revisa el contenido actual.";
  }
  if (row?.status === "capacity") {
    return "No hay capacidad disponible para conservar los adjuntos de la versión anterior.";
  }
  if (row?.status === "expired") {
    return "La vista previa venció. Prepara la operación otra vez.";
  }
  if (row?.status === "member_conflict") {
    return "Un integrante elegido ya no tiene acceso a este tablero. Prepara y revisa otra vez las asignaciones.";
  }
  if (row?.status === "label_conflict") {
    return "Un nombre de etiqueta ya no está disponible. Elige otro nombre antes de confirmar.";
  }
  if (typeof row?.message === "string") return row.message;
  return fallback;
}

function formatBytes(bytes: number): string {
  if (bytes < 1000) return `${bytes} bytes`;
  if (bytes < 1_000_000) return `${(bytes / 1000).toFixed(1)} KB`;
  return `${(bytes / 1_000_000).toFixed(1)} MB`;
}

function describeGeneration(summary: GenerationSummary): string {
  const attachmentText =
    summary.attachments === 1 ? "1 adjunto" : `${summary.attachments} adjuntos`;
  return `${summary.columns} columnas, ${summary.tasks} tareas, ${summary.comments} comentarios, ${summary.labels} etiquetas, ${summary.birthdays} cumpleaños, ${summary.series} series y ${attachmentText} (${formatBytes(summary.attachment_bytes)})`;
}

function formatDate(value: string): string {
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? "fecha no disponible"
    : date.toLocaleString();
}

interface BoardImportDialogProps {
  open: boolean;
  slug: string;
  onClose: () => void;
  onConfirmed: () => Promise<void>;
}

export function BoardImportDialog({
  open,
  slug,
  onClose,
  onConfirmed,
}: BoardImportDialogProps) {
  const [file, setFile] = useState<File | null>(null);
  const [importPreview, setImportPreview] = useState<ImportPreview | null>(
    null,
  );
  const [pendingPreparation, setPendingPreparation] =
    useState<PendingPreparation | null>(null);
  const [assigneeMappings, setAssigneeMappings] = useState<
    Record<string, string>
  >({});
  const [labelConflicts, setLabelConflicts] = useState<LabelConflict[]>([]);
  const [labelResolutions, setLabelResolutions] = useState<
    Record<string, string>
  >({});
  const [isPreparing, setIsPreparing] = useState(false);
  const [isSavingDecisions, setIsSavingDecisions] = useState(false);
  const [isConfirming, setIsConfirming] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    setFile(null);
    setImportPreview(null);
    setAssigneeMappings({});
    setLabelConflicts([]);
    setLabelResolutions({});
    setError(null);
    setNotice(null);
  }, [open]);

  function handleClose() {
    if (isPreparing || isSavingDecisions || isConfirming) return;
    onClose();
  }

  function handleFileChange(event: React.ChangeEvent<HTMLInputElement>) {
    const selected = event.target.files?.[0] ?? null;
    setFile(selected);
    setPendingPreparation((pending) =>
      selected &&
      pending?.fileName === selected.name &&
      pending.fileSize === selected.size &&
      pending.fileLastModified === selected.lastModified
        ? pending
        : null,
    );
    setImportPreview(null);
    setAssigneeMappings({});
    setLabelConflicts([]);
    setLabelResolutions({});
    setError(null);
    setNotice(null);
  }

  async function prepareImport() {
    if (!file || isPreparing) return;
    const isPortableV2 = file.name.toLowerCase().endsWith(".zip");
    const maximumBytes = isPortableV2
      ? MAX_PORTABLE_BOARD_IMPORT_BYTES
      : MAX_LEGACY_BOARD_IMPORT_BYTES;
    if (file.size > maximumBytes) {
      setError(
        isPortableV2
          ? "El respaldo ZIP supera el límite técnico permitido."
          : "El respaldo JSON supera el límite de 2 MiB.",
      );
      return;
    }
    setIsPreparing(true);
    setError(null);
    setNotice(null);
    try {
      const operationId =
        pendingPreparation?.operationId ?? crypto.randomUUID();
      setPendingPreparation({
        operationId,
        fileName: file.name,
        fileSize: file.size,
        fileLastModified: file.lastModified,
      });
      const endpoint = `/api/boards/${encodeURIComponent(slug)}/import`;
      const response = isPortableV2
        ? await fetch(endpoint, {
            method: "POST",
            body: file,
            cache: "no-store",
            headers: {
              "Content-Type": "application/zip",
              "X-Operation-Id": operationId,
            },
          })
        : await (() => {
            const form = new FormData();
            form.set("operation_id", operationId);
            form.set("file", file);
            return fetch(endpoint, {
              method: "POST",
              body: form,
              cache: "no-store",
            });
          })();
      const body: unknown = await response.json();
      if (response.ok && asRecord(body)?.status === "confirmed") {
        setPendingPreparation(null);
        setImportPreview(null);
        try {
          await onConfirmed();
          onClose();
        } catch {
          setNotice(
            "El reemplazo ya estaba confirmado, pero no se pudo actualizar la vista. Recarga la página para ver el contenido nuevo.",
          );
        }
        return;
      }
      const parsed = parsePreview(body);
      if (parsed?.status === "label_conflict") {
        if (!isPortableV2 || parsed.operation_id !== operationId) {
          setPendingPreparation(null);
          setError("No se pudo revisar la colisión de etiquetas del respaldo.");
          return;
        }
        setPendingPreparation(null);
        setImportPreview(parsed);
        setAssigneeMappings(
          Object.fromEntries(
            parsed.member_refs.map((reference) => {
              const mapping = parsed.member_mappings.find(
                (item) => item.source_ref === reference,
              );
              return [
                reference,
                mapping?.target_user_id ??
                  (parsed.member_mappings.some(
                    (item) => item.source_ref === reference,
                  )
                    ? "__unassigned"
                    : ""),
              ];
            }),
          ),
        );
        setLabelConflicts(parsed.label_conflicts);
        setLabelResolutions((current) =>
          Object.fromEntries(
            parsed.label_conflicts.map((conflict) => [
              conflict.source_ref,
              current[conflict.source_ref] ?? "",
            ]),
          ),
        );
        setError(
          "El respaldo está preparado en segundo plano. Elige responsables y nombres nuevos para las etiquetas; el tablero actual sigue intacto.",
        );
        return;
      }
      if (!response.ok || !parsed || parsed.source_sha256 === undefined) {
        if (
          [
            "cancelled",
            "capacity",
            "conflict",
            "expired",
            "invalid",
            "storage",
            "too_large",
            "unavailable",
          ].includes(String(asRecord(body)?.status))
        ) {
          setPendingPreparation(null);
        }
        setError(
          describeError(
            body,
            isPortableV2
              ? "No se pudo preparar el respaldo v2. El tablero actual no cambió."
              : "No se pudo preparar el respaldo v1.",
          ),
        );
        return;
      }
      setPendingPreparation(null);
      setLabelConflicts([]);
      setLabelResolutions({});
      setAssigneeMappings(
        Object.fromEntries(
          parsed.member_refs.map((reference) => {
            const mapping = parsed.member_mappings.find(
              (item) => item.source_ref === reference,
            );
            return [
              reference,
              mapping?.target_user_id ??
                (parsed.member_mappings.some(
                  (item) => item.source_ref === reference,
                )
                  ? "__unassigned"
                  : ""),
            ];
          }),
        ),
      );
      setImportPreview(parsed);
    } catch {
      setError(
        "No se pudo confirmar el resultado de la preparación. Vuelve a intentarlo con el mismo archivo para consultar la misma operación.",
      );
    } finally {
      setIsPreparing(false);
    }
  }

  async function saveDecisions() {
    if (!importPreview || isSavingDecisions) return;
    const resolutions = labelConflicts.map((conflict) => ({
      source_ref: conflict.source_ref,
      name: labelResolutions[conflict.source_ref]?.trim() ?? "",
    }));
    const memberMappings = importPreview.member_refs.map((sourceRef) => {
      const target = assigneeMappings[sourceRef];
      return {
        source_ref: sourceRef,
        target_user_id: target === "__unassigned" ? null : target,
      };
    });
    if (
      resolutions.some(
        (resolution) =>
          resolution.name.length < 1 || resolution.name.length > 40,
      ) ||
      memberMappings.some(
        (mapping) =>
          mapping.target_user_id === "" || mapping.target_user_id === undefined,
      )
    ) {
      setError(
        "Completa las decisiones de etiqueta y responsable antes de continuar.",
      );
      return;
    }
    const requestBody = JSON.stringify({
      label_resolutions: resolutions,
      member_mappings: memberMappings,
    });
    if (
      new TextEncoder().encode(requestBody).byteLength >
      MAX_PORTABLE_BOARD_IMPORT_DECISION_BYTES
    ) {
      setError("La lista de decisiones supera el límite técnico permitido.");
      return;
    }
    setIsSavingDecisions(true);
    setError(null);
    setNotice(null);
    try {
      const response = await fetch(
        `/api/boards/${encodeURIComponent(slug)}/import/${encodeURIComponent(importPreview.operation_id)}/labels`,
        {
          method: "POST",
          cache: "no-store",
          headers: { "Content-Type": "application/json" },
          body: requestBody,
        },
      );
      const body: unknown = await response.json();
      const parsed = parsePreview(body);
      if (parsed?.status === "label_conflict") {
        setImportPreview(parsed);
        setLabelConflicts(parsed.label_conflicts);
        setLabelResolutions((current) =>
          Object.fromEntries(
            parsed.label_conflicts.map((conflict) => [
              conflict.source_ref,
              current[conflict.source_ref] ?? "",
            ]),
          ),
        );
        setError(
          "Algún nombre sigue en conflicto. El tablero actual no cambió; elige otro nombre y vuelve a guardar las decisiones.",
        );
        return;
      }
      if (parsed?.status === "member_conflict") {
        const currentMembers = new Set(
          parsed.members.map((member) => member.user_id),
        );
        setImportPreview(parsed);
        setAssigneeMappings((current) =>
          Object.fromEntries(
            parsed.member_refs.map((reference) => {
              const target = current[reference];
              return [
                reference,
                target === "__unassigned" ||
                (target && currentMembers.has(target))
                  ? target
                  : "",
              ];
            }),
          ),
        );
        setError(
          "Un integrante ya no tiene acceso. Revisa de nuevo cada responsable con la lista vigente del tablero.",
        );
        return;
      }
      if (!response.ok || !parsed || parsed.status !== "prepared") {
        setError(
          describeError(
            body,
            "No se pudieron guardar las decisiones. El tablero actual no cambió.",
          ),
        );
        return;
      }
      setImportPreview(parsed);
      setLabelConflicts([]);
      setLabelResolutions({});
      setAssigneeMappings(
        Object.fromEntries(
          parsed.member_refs.map((reference) => {
            const mapping = parsed.member_mappings.find(
              (item) => item.source_ref === reference,
            );
            return [
              reference,
              mapping ? (mapping.target_user_id ?? "__unassigned") : "",
            ];
          }),
        ),
      );
      setNotice(
        "Las decisiones se guardaron. Revisa la vista previa antes de confirmar el reemplazo.",
      );
    } catch {
      setError(
        "No se pudo confirmar el resultado de las decisiones. Vuelve a enviarlas desde esta misma vista previa.",
      );
    } finally {
      setIsSavingDecisions(false);
    }
  }

  async function confirmImport() {
    if (
      !importPreview?.source_sha256 ||
      importPreview.status !== "prepared" ||
      isConfirming
    )
      return;
    const memberMappings = importPreview.member_refs.map((sourceRef) => {
      const target = assigneeMappings[sourceRef];
      return {
        source_ref: sourceRef,
        target_user_id: target === "__unassigned" ? null : target,
      };
    });
    if (
      importPreview.source_version === 2 &&
      memberMappings.some(
        (mapping) =>
          mapping.target_user_id === "" || mapping.target_user_id === undefined,
      )
    ) {
      setError(
        "Decide a qué integrante actual asignar cada persona importada o marca que quede sin asignar.",
      );
      return;
    }
    const requestBody = JSON.stringify({
      source_sha256: importPreview.source_sha256,
      expected_content_revision: importPreview.content_revision,
      ...(importPreview.source_version === 2
        ? { member_mappings: memberMappings }
        : {}),
    });
    if (
      new TextEncoder().encode(requestBody).byteLength >
      MAX_PORTABLE_BOARD_IMPORT_DECISION_BYTES
    ) {
      setError("La lista de asignaciones supera el límite técnico permitido.");
      return;
    }
    setIsConfirming(true);
    setError(null);
    setNotice(null);
    try {
      const response = await fetch(
        `/api/boards/${encodeURIComponent(slug)}/import/${encodeURIComponent(importPreview.operation_id)}/confirm`,
        {
          method: "POST",
          cache: "no-store",
          headers: { "Content-Type": "application/json" },
          body: requestBody,
        },
      );
      const body: unknown = await response.json();
      if (!response.ok || asRecord(body)?.status !== "confirmed") {
        const resultStatus = asRecord(body)?.status;
        const updatedPreview = parsePreview(body);
        if (
          updatedPreview &&
          (resultStatus === "label_conflict" ||
            resultStatus === "member_conflict")
        ) {
          setImportPreview(updatedPreview);
          if (resultStatus === "label_conflict") {
            setLabelConflicts(updatedPreview.label_conflicts);
            setLabelResolutions((current) =>
              Object.fromEntries(
                updatedPreview.label_conflicts.map((conflict) => [
                  conflict.source_ref,
                  current[conflict.source_ref] ?? "",
                ]),
              ),
            );
          } else {
            const currentMembers = new Set(
              updatedPreview.members.map((member) => member.user_id),
            );
            setAssigneeMappings((current) =>
              Object.fromEntries(
                updatedPreview.member_refs.map((reference) => {
                  const target = current[reference];
                  return [
                    reference,
                    target === "__unassigned" ||
                    (target && currentMembers.has(target))
                      ? target
                      : "",
                  ];
                }),
              ),
            );
          }
        } else if (resultStatus === "conflict") {
          setImportPreview(null);
          setAssigneeMappings({});
        }
        setError(describeError(body, "No se pudo confirmar el reemplazo."));
        return;
      }
      setImportPreview(null);
      try {
        await onConfirmed();
        onClose();
      } catch {
        setNotice(
          "El reemplazo se confirmó, pero no se pudo actualizar la vista. Recarga la página para ver el contenido nuevo.",
        );
      }
    } catch {
      setError(
        "No se pudo confirmar el resultado del reemplazo. Vuelve a confirmar la misma vista previa sin volver a cargar el archivo.",
      );
    } finally {
      setIsConfirming(false);
    }
  }

  const busy = isPreparing || isSavingDecisions || isConfirming;

  return (
    <Modal
      open={open}
      onClose={handleClose}
      title="Importar respaldos v1 o v2"
      fullScreenMobile
    >
      <div className="space-y-5 text-sm text-text-secondary leading-relaxed">
        <section className="space-y-3" aria-labelledby="board-import-heading">
          <h3
            id="board-import-heading"
            className="font-medium text-text-primary"
          >
            Reemplazar el contenido del tablero
          </h3>
          <p>
            Se reemplazará el contenido actual; no se combinarán las tareas. Se
            conservarán el propietario y los integrantes de este tablero.
          </p>
          <p>
            El respaldo v1 aporta columnas y tareas. El respaldo v2 puede
            incluir etiquetas, cumpleaños, comentarios, actividad, calendario de
            series y adjuntos. Los responsables se mapean explícitamente a
            integrantes actuales o quedan sin asignar; las menciones permanecen
            como texto y nunca se crean avisos antiguos.
          </p>
          <p>
            La versión anterior se conserva durante siete días. Sus adjuntos
            siguen contando para la capacidad mientras esté retenida.
          </p>
          <label className="block space-y-1.5 text-text-primary">
            <span>Archivo JSON v1 o ZIP v2</span>
            <input
              type="file"
              accept=".json,application/json,.zip,application/zip"
              onChange={handleFileChange}
              disabled={busy}
              className="block w-full rounded-md border border-border bg-surface-base px-3 py-2 text-text-secondary"
            />
          </label>
          {file ? (
            <p aria-live="polite">
              {file.name} · {formatBytes(file.size)}
            </p>
          ) : null}
          {labelConflicts.length > 0 ? (
            <fieldset className="space-y-3 rounded-md border border-border bg-surface-raised p-3">
              <legend className="px-1 font-medium text-text-primary">
                Resolver nombres de etiquetas
              </legend>
              <p>
                Las etiquetas nuevas conservan sus identificadores y relaciones.
                Para evitar fusionarlas con las retenidas, elige un nombre
                normalizado que esté disponible para cada conflicto.
              </p>
              {labelConflicts.map((conflict, index) => (
                <label
                  key={conflict.source_ref}
                  htmlFor={`import-label-resolution-${index}`}
                  className="block space-y-1.5 text-text-primary"
                >
                  <span>
                    «{conflict.name}» entra en conflicto con «
                    {conflict.conflict_name}».
                  </span>
                  <input
                    id={`import-label-resolution-${index}`}
                    type="text"
                    maxLength={40}
                    value={labelResolutions[conflict.source_ref] ?? ""}
                    onChange={(event) =>
                      setLabelResolutions((current) => ({
                        ...current,
                        [conflict.source_ref]: event.target.value,
                      }))
                    }
                    disabled={busy}
                    className="block w-full rounded-md border border-border bg-surface-base px-3 py-2 text-text-secondary"
                  />
                </label>
              ))}
              <p>
                Las decisiones se aplicarán a la preparación guardada. No tienes
                que volver a seleccionar ni subir el archivo. El tablero actual
                seguirá intacto hasta confirmar el reemplazo.
              </p>
            </fieldset>
          ) : null}
          <div className="flex flex-wrap items-center gap-2">
            <Button
              variant="primary"
              onClick={() => void prepareImport()}
              disabled={
                !file ||
                busy ||
                importPreview !== null ||
                labelConflicts.some(
                  (conflict) =>
                    !labelResolutions[conflict.source_ref]?.trim() ||
                    labelResolutions[conflict.source_ref].trim().length > 40,
                )
              }
              aria-busy={isPreparing}
            >
              {isPreparing
                ? "Preparando vista previa…"
                : labelConflicts.length > 0
                  ? "Revisar nombres y preparar"
                  : "Preparar vista previa"}
            </Button>
          </div>
          {importPreview?.imported ? (
            <div className="space-y-2 rounded-md border border-border bg-surface-raised p-3">
              <p>
                <strong className="text-text-primary">Contenido actual:</strong>{" "}
                {describeGeneration(importPreview.current)}
              </p>
              <p>
                <strong className="text-text-primary">
                  Respaldo v{importPreview.source_version}:
                </strong>{" "}
                {describeGeneration(importPreview.imported)}
              </p>
              <p>Revisión del contenido: {importPreview.content_revision}</p>
              <p>
                Capacidad utilizada:{" "}
                {formatBytes(importPreview.capacity.used_bytes)} de{" "}
                {formatBytes(importPreview.capacity.limit_bytes)}. Se
                conservarían{" "}
                {formatBytes(importPreview.current.attachment_bytes)} en
                adjuntos anteriores.
              </p>
              <p>
                Esta vista previa vence {formatDate(importPreview.expires_at)}.
                Vuelve a prepararla si el tablero cambia.
              </p>
              {importPreview.label_renames.length > 0 ? (
                <div className="space-y-1">
                  <p className="font-medium text-text-primary">
                    Nombres de etiquetas elegidos:
                  </p>
                  {importPreview.label_renames.map((rename) => (
                    <p key={rename.source_ref}>
                      «{rename.name}» se importará como «{rename.imported_name}
                      ».
                    </p>
                  ))}
                </div>
              ) : null}
              {importPreview.source_version === 2 &&
              importPreview.member_refs.length > 0 ? (
                <fieldset className="space-y-3 rounded-md border border-border p-3">
                  <legend className="px-1 font-medium text-text-primary">
                    Responsables del respaldo
                  </legend>
                  <p>
                    Las referencias del paquete no revelan identidades. Elige un
                    integrante vigente para cada persona o déjala sin asignar.
                    No se buscará por nombre ni se invitará a nadie.
                  </p>
                  {importPreview.member_refs.map((reference, index) => (
                    <label
                      key={reference}
                      htmlFor={`import-member-mapping-${index}`}
                      className="block space-y-1.5 text-text-primary"
                    >
                      <span>Persona importada {index + 1}</span>
                      <select
                        id={`import-member-mapping-${index}`}
                        value={assigneeMappings[reference] ?? ""}
                        onChange={(event) =>
                          setAssigneeMappings((current) => ({
                            ...current,
                            [reference]: event.target.value,
                          }))
                        }
                        disabled={busy}
                        className="block w-full rounded-md border border-border bg-surface-base px-3 py-2 text-text-secondary"
                      >
                        <option value="">Elige una opción</option>
                        <option value="__unassigned">Dejar sin asignar</option>
                        {importPreview.members.map((member) => (
                          <option key={member.user_id} value={member.user_id}>
                            {member.name}
                          </option>
                        ))}
                      </select>
                    </label>
                  ))}
                </fieldset>
              ) : null}
              <div className="flex flex-wrap gap-2">
                {labelConflicts.length > 0 ? (
                  <Button
                    variant="primary"
                    onClick={() => void saveDecisions()}
                    disabled={
                      busy ||
                      labelConflicts.some(
                        (conflict) =>
                          !labelResolutions[conflict.source_ref]?.trim() ||
                          labelResolutions[conflict.source_ref].trim().length >
                            40,
                      ) ||
                      importPreview.member_refs.some(
                        (reference) => !assigneeMappings[reference],
                      )
                    }
                    aria-busy={isSavingDecisions}
                  >
                    {isSavingDecisions
                      ? "Guardando decisiones…"
                      : "Guardar decisiones y continuar"}
                  </Button>
                ) : (
                  <Button
                    variant="primary"
                    onClick={() => void confirmImport()}
                    disabled={
                      busy ||
                      importPreview.status !== "prepared" ||
                      !importPreview.capacity.can_replace ||
                      (importPreview.source_version === 2 &&
                        importPreview.member_refs.some(
                          (reference) => !assigneeMappings[reference],
                        ))
                    }
                    aria-busy={isConfirming}
                  >
                    {isConfirming ? "Reemplazando…" : "Confirmar reemplazo"}
                  </Button>
                )}
                <Button
                  onClick={() => {
                    setImportPreview(null);
                    setNotice(
                      "Vista previa descartada. El tablero actual no cambió.",
                    );
                  }}
                  disabled={busy}
                >
                  Descartar vista previa
                </Button>
              </div>
              {!importPreview.capacity.can_replace ? (
                <p role="alert" className="text-priority-urgent">
                  No se puede conservar la versión anterior con la capacidad
                  actual.
                </p>
              ) : null}
            </div>
          ) : null}
        </section>

        {error ? (
          <p role="alert" className="text-priority-urgent">
            {error}
          </p>
        ) : null}
        {notice ? (
          <output aria-live="polite" className="text-text-primary">
            {notice}
          </output>
        ) : null}
        <div className="flex justify-end border-border border-t pt-3">
          <Button onClick={handleClose} disabled={busy}>
            Cerrar
          </Button>
        </div>
      </div>
    </Modal>
  );
}
