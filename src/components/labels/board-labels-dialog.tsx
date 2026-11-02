"use client";

import { IconTag, IconTrash } from "@tabler/icons-react";
import {
  type FormEvent,
  useCallback,
  useEffect,
  useId,
  useMemo,
  useState,
} from "react";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { Modal } from "@/components/ui/modal";
import {
  type BoardLabelDraft,
  type BoardLabelDraftConflict,
  createBoardLabelDraft,
  isBoardLabelDraftDirty,
  type OrphanedBoardLabelDrafts,
  reconcileBoardLabelCatalogRead,
  reconcileBoardLabelDrafts,
  resolveBoardLabelDraftConflict,
} from "@/lib/board-label-edit-state";
import { reconcileRestoreSelection } from "@/lib/board-label-restore-state";
import {
  type BoardLabelRestorePreview,
  BoardLabelsUnavailableError,
  createBoardLabel,
  type DeletedBoardLabel,
  deleteBoardLabel,
  listBoardLabels,
  listDeletedBoardLabels,
  previewRestoreBoardLabel,
  restoreBoardLabel,
  updateBoardLabel,
} from "@/lib/db/board-labels";
import { createClient } from "@/lib/supabase/client";
import type { BoardLabel, BoardLabelColor } from "@/lib/types";

const colors: { value: BoardLabelColor; label: string }[] = [
  { value: "red", label: "Rojo" },
  { value: "orange", label: "Naranja" },
  { value: "yellow", label: "Amarillo" },
  { value: "green", label: "Verde" },
  { value: "teal", label: "Verde azulado" },
  { value: "blue", label: "Azul" },
  { value: "purple", label: "Violeta" },
  { value: "pink", label: "Rosa" },
  { value: "gray", label: "Gris" },
];

function resultMessage(status: string, reason?: string) {
  if (status === "unavailable") {
    return "El tablero o la etiqueta ya no están disponibles con tu acceso actual.";
  }
  if (status === "expired")
    return "Ya venció el plazo de recuperación de 7 días.";
  if (reason === "duplicate_name") {
    return "Ya existe una etiqueta activa con un nombre equivalente. Elegí otro nombre.";
  }
  if (reason === "active_limit") {
    return "El tablero ya tiene 100 etiquetas activas. Quitá una antes de continuar.";
  }
  if (reason === "stale_version") {
    return "La etiqueta cambió en otra sesión. Actualizamos el catálogo; revisá antes de guardar.";
  }
  if (reason === "too_many_labels") {
    return "Algún elemento seleccionado ya tiene 10 etiquetas. Actualizá la vista previa y elegí qué relaciones conservar.";
  }
  return "No se pudo confirmar el cambio. Revisá los datos e intentá de nuevo.";
}

function expirationLabel(value: string) {
  return new Intl.DateTimeFormat("es-AR", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}

export function BoardLabelsDialog({
  open,
  onClose,
  slug,
  role,
  labels,
  onLabelsChange,
  onChanged,
}: {
  open: boolean;
  onClose: () => void;
  slug: string;
  role: "owner" | "collaborator";
  labels: BoardLabel[];
  onLabelsChange: (labels: BoardLabel[]) => void;
  onChanged: () => Promise<void>;
}) {
  const supabase = useMemo(() => createClient(), []);
  const [trash, setTrash] = useState<DeletedBoardLabel[]>([]);
  const [drafts, setDrafts] = useState<Record<string, BoardLabelDraft>>({});
  const [labelConflicts, setLabelConflicts] = useState<
    Record<string, BoardLabelDraftConflict>
  >({});
  const [orphanedDrafts, setOrphanedDrafts] =
    useState<OrphanedBoardLabelDrafts>({});
  const [newName, setNewName] = useState("");
  const [newColor, setNewColor] = useState<BoardLabelColor>("blue");
  const [deleteTarget, setDeleteTarget] = useState<BoardLabel | null>(null);
  const [restoreTarget, setRestoreTarget] = useState<DeletedBoardLabel | null>(
    null,
  );
  const [preview, setPreview] = useState<BoardLabelRestorePreview | null>(null);
  const [restoreNeedsReview, setRestoreNeedsReview] = useState(false);
  const [restoreName, setRestoreName] = useState("");
  const [selectedTasks, setSelectedTasks] = useState<string[]>([]);
  const [selectedBirthdays, setSelectedBirthdays] = useState<string[]>([]);
  const [loading, setLoading] = useState(false);
  const [catalogReadFailed, setCatalogReadFailed] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const nameId = useId();
  const errorId = useId();

  const clearDialogDrafts = useCallback(() => {
    setTrash([]);
    setDrafts({});
    setOrphanedDrafts({});
    setLabelConflicts({});
    setDeleteTarget(null);
    setRestoreTarget(null);
    setPreview(null);
    setRestoreNeedsReview(false);
    setRestoreName("");
    setSelectedTasks([]);
    setSelectedBirthdays([]);
    setNewName("");
    setNewColor("blue");
    setNotice(null);
    setError(null);
    setCatalogReadFailed(false);
  }, []);

  const clearPrivateCatalogContent = useCallback(() => {
    clearDialogDrafts();
    onLabelsChange([]);
  }, [clearDialogDrafts, onLabelsChange]);

  function handleClose() {
    onClose();
  }

  useEffect(() => {
    setDrafts((current) => reconcileBoardLabelDrafts(labels, current));
  }, [labels]);

  useEffect(() => {
    if (!open) return;
    let disposed = false;
    setError(null);
    setNotice(null);
    setCatalogReadFailed(false);
    setLoading(true);
    Promise.all([
      listBoardLabels(supabase, slug),
      role === "owner"
        ? listDeletedBoardLabels(supabase, slug).catch(() => [])
        : Promise.resolve([]),
    ])
      .then(([active, deleted]) => {
        if (disposed) return;
        onLabelsChange(active);
        setTrash(deleted);
      })
      .catch((failure: unknown) => {
        if (!disposed) {
          if (failure instanceof BoardLabelsUnavailableError) {
            clearPrivateCatalogContent();
            setError("El tablero ya no está disponible con tu acceso actual.");
          } else {
            setCatalogReadFailed(true);
            setError(
              "No se pudo cargar el catálogo. Conservamos las etiquetas, filtros y borradores; revisá la conexión y reintentá.",
            );
          }
        }
      })
      .finally(() => {
        if (!disposed) setLoading(false);
      });
    return () => {
      disposed = true;
    };
  }, [clearPrivateCatalogContent, onLabelsChange, open, role, slug, supabase]);

  async function refreshCatalog(): Promise<BoardLabel[]> {
    let active: BoardLabel[];
    try {
      active = await listBoardLabels(supabase, slug);
    } catch (failure) {
      if (failure instanceof BoardLabelsUnavailableError) {
        clearPrivateCatalogContent();
      } else {
        setCatalogReadFailed(true);
      }
      throw failure;
    }
    setCatalogReadFailed(false);
    const editorState = reconcileBoardLabelCatalogRead({
      status: "available",
      slug,
      labels: active,
      previousLabels: labels,
      drafts,
      orphanedDrafts,
    });
    setDrafts(editorState.drafts);
    setOrphanedDrafts(editorState.orphanedDrafts);
    onLabelsChange(active);
    setLabelConflicts((current) => {
      const refreshed = Object.fromEntries(
        Object.entries(current).flatMap(([labelId, conflict]) => {
          const latest = active.find((label) => label.id === labelId);
          return latest ? [[labelId, { ...conflict, current: latest }]] : [];
        }),
      );
      return { ...refreshed, ...editorState.pendingConflicts };
    });
    if (role === "owner") {
      try {
        setTrash(await listDeletedBoardLabels(supabase, slug));
      } catch {
        setTrash([]);
      }
    } else {
      setTrash([]);
    }
    await onChanged();
    return active;
  }

  async function retryCatalogRead() {
    if (loading) return;
    setLoading(true);
    setError(null);
    setNotice(null);
    try {
      await refreshCatalog();
      setNotice("Se actualizó el catálogo de etiquetas.");
    } catch (failure) {
      setError(
        failure instanceof BoardLabelsUnavailableError
          ? "El tablero ya no está disponible con tu acceso actual. Limpiamos el contenido privado."
          : "La lectura sigue sin completarse. Conservamos los datos locales; reintentá cuando vuelva la conexión.",
      );
    } finally {
      setLoading(false);
    }
  }

  async function createLabel(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (loading || labels.length >= 100) return;
    setLoading(true);
    setError(null);
    setNotice(null);
    try {
      const result = await createBoardLabel(supabase, {
        slug,
        name: newName,
        color: newColor,
      });
      if (result.status !== "confirmed") {
        if (result.status === "unavailable") {
          clearPrivateCatalogContent();
          setError(
            "El tablero ya no está disponible con tu acceso actual. Limpiamos el contenido privado.",
          );
          return;
        }
        setError(resultMessage(result.status, result.reason));
        return;
      }
      setNewName("");
      setNotice("Se creó la etiqueta.");
      await refreshCatalog();
    } catch (failure) {
      setError(
        failure instanceof BoardLabelsUnavailableError
          ? "El tablero ya no está disponible con tu acceso actual. Limpiamos el contenido privado."
          : "No se pudo crear la etiqueta. Conservamos el nombre escrito; podés reintentar.",
      );
    } finally {
      setLoading(false);
    }
  }

  async function saveLabel(label: BoardLabel) {
    const draft = drafts[label.id];
    if (!draft || labelConflicts[label.id] || loading) return;
    setLoading(true);
    setError(null);
    setNotice(null);
    try {
      const result = await updateBoardLabel(supabase, {
        slug,
        labelId: label.id,
        expectedVersion: draft.baseVersion,
        name: draft.name,
        color: draft.color,
      });
      if (result.status !== "confirmed") {
        if (result.status === "unavailable") {
          clearPrivateCatalogContent();
          setError(
            "El tablero ya no está disponible con tu acceso actual. Limpiamos el contenido privado.",
          );
          return;
        }
        if (result.reason === "stale_version") {
          setError(null);
          const active = await refreshCatalog();
          const current = active.find((item) => item.id === label.id);
          if (current) {
            setLabelConflicts((existing) => ({
              ...existing,
              [label.id]: { current, proposal: draft },
            }));
          } else {
            setError(resultMessage(result.status, result.reason));
          }
        } else {
          setError(resultMessage(result.status, result.reason));
          await refreshCatalog();
        }
        return;
      }
      setNotice("Se guardaron el nombre y el color.");
      const active = await refreshCatalog();
      const updated = active.find((item) => item.id === label.id);
      if (updated) {
        setDrafts((current) => ({
          ...current,
          [label.id]: createBoardLabelDraft(updated),
        }));
      }
      setLabelConflicts((current) => {
        const { [label.id]: _removed, ...remaining } = current;
        return remaining;
      });
    } catch (failure) {
      setError(
        failure instanceof BoardLabelsUnavailableError
          ? "El tablero ya no está disponible con tu acceso actual. Limpiamos el contenido privado."
          : "No se pudo guardar la etiqueta. Conservamos los cambios escritos; podés reintentar.",
      );
    } finally {
      setLoading(false);
    }
  }

  function resolveLabelVersionConflict(
    labelId: string,
    resolution: "use_current" | "keep_draft",
  ) {
    const conflict = labelConflicts[labelId];
    if (!conflict) return;
    const current = conflict.current;
    setDrafts((draftMap) => {
      return {
        ...draftMap,
        [labelId]: resolveBoardLabelDraftConflict(
          conflict.proposal,
          current,
          resolution,
        ),
      };
    });
    setLabelConflicts((existing) => {
      const { [labelId]: _removed, ...remaining } = existing;
      return remaining;
    });
    setNotice(
      resolution === "use_current"
        ? "Descartaste tu edición y aplicaste la versión actual de la etiqueta."
        : "Conservamos tu edición sobre la versión actual. Revisala y guardala cuando quieras.",
    );
  }

  function discardOrphanedDraft(labelId: string) {
    setOrphanedDrafts((current) => {
      const { [labelId]: _removed, ...remaining } = current;
      return remaining;
    });
    setNotice("Descartaste el borrador local de la etiqueta ya no disponible.");
  }

  async function confirmDelete() {
    if (!deleteTarget || loading) return;
    setLoading(true);
    setError(null);
    setNotice(null);
    try {
      const result = await deleteBoardLabel(supabase, {
        slug,
        labelId: deleteTarget.id,
        expectedVersion: deleteTarget.version,
      });
      if (result.status !== "confirmed") {
        if (result.status === "unavailable") {
          clearPrivateCatalogContent();
          setError(
            "El tablero ya no está disponible con tu acceso actual. Limpiamos el contenido privado.",
          );
          return;
        }
        setError(resultMessage(result.status, result.reason));
        await refreshCatalog();
        return;
      }
      setDeleteTarget(null);
      setNotice(
        "La etiqueta quedó oculta y se puede recuperar durante 7 días.",
      );
      await refreshCatalog();
    } catch (failure) {
      setError(
        failure instanceof BoardLabelsUnavailableError
          ? "El tablero ya no está disponible con tu acceso actual. Limpiamos el contenido privado."
          : "No se pudo confirmar el borrado. Conservamos el estado local; podés reintentar.",
      );
    } finally {
      setLoading(false);
    }
  }

  async function loadPreview(
    label: DeletedBoardLabel,
    name = restoreName,
    {
      preserveSelections = false,
      requireReview = false,
    }: { preserveSelections?: boolean; requireReview?: boolean } = {},
  ): Promise<boolean> {
    setLoading(true);
    setError(null);
    try {
      const next = await previewRestoreBoardLabel(supabase, {
        slug,
        labelId: label.id,
        name,
      });
      if (next.status === "unavailable") {
        clearPrivateCatalogContent();
        setError(
          "El tablero ya no está disponible con tu acceso actual. Limpiamos el contenido privado.",
        );
        return false;
      }
      setRestoreTarget(next.label ?? label);
      setRestoreName(name);
      setPreview(next);
      setRestoreNeedsReview(requireReview);
      if (next.status === "preview") {
        setSelectedTasks((current) =>
          reconcileRestoreSelection(
            current,
            next.associated_tasks.map((item) => item.id),
            preserveSelections,
          ),
        );
        setSelectedBirthdays((current) =>
          reconcileRestoreSelection(
            current,
            next.associated_birthdays.map((item) => item.id),
            preserveSelections,
          ),
        );
      } else if (next.status === "expired") {
        setError(resultMessage("expired"));
      }
      return next.status === "preview" && next.label !== undefined;
    } catch (failure) {
      setError(
        failure instanceof BoardLabelsUnavailableError
          ? "El tablero ya no está disponible con tu acceso actual. Limpiamos el contenido privado."
          : "No se pudo preparar la vista previa. Conservamos tu borrador; podés reintentar.",
      );
      return false;
    } finally {
      setLoading(false);
    }
  }

  async function reviewRestoreVersion() {
    if (!restoreTarget || loading) return;
    const refreshed = await loadPreview(restoreTarget, restoreName, {
      preserveSelections: true,
      requireReview: true,
    });
    if (refreshed) {
      setRestoreNeedsReview(false);
      setNotice(
        "Revisaste la versión actual. Tu propuesta sigue seleccionada.",
      );
    }
  }

  async function confirmRestore() {
    if (!restoreTarget || !preview?.label || !canConfirmRestore || loading)
      return;
    setLoading(true);
    setError(null);
    setNotice(null);
    try {
      const result = await restoreBoardLabel(supabase, {
        slug,
        labelId: restoreTarget.id,
        expectedVersion: preview.label.version,
        name: restoreName,
        taskIds: selectedTasks,
        birthdayIds: selectedBirthdays,
      });
      if (result.status !== "confirmed") {
        if (result.status === "unavailable") {
          clearPrivateCatalogContent();
          setError(
            "El tablero ya no está disponible con tu acceso actual. Limpiamos el contenido privado.",
          );
          return;
        }
        const staleVersion = result.reason === "stale_version";
        setError(
          staleVersion ? null : resultMessage(result.status, result.reason),
        );
        await loadPreview(restoreTarget, restoreName, {
          preserveSelections: true,
          requireReview: staleVersion || restoreNeedsReview,
        });
        return;
      }
      setRestoreTarget(null);
      setPreview(null);
      setRestoreNeedsReview(false);
      setNotice("Se recuperó la etiqueta y las relaciones elegidas.");
      await refreshCatalog();
    } catch (failure) {
      setError(
        failure instanceof BoardLabelsUnavailableError
          ? "El tablero ya no está disponible con tu acceso actual. Limpiamos el contenido privado."
          : "No se pudo confirmar la recuperación. Conservamos la vista previa; revisá la conexión y reintentá.",
      );
    } finally {
      setLoading(false);
    }
  }

  const previewTasks = preview?.associated_tasks ?? [];
  const previewBirthdays = preview?.associated_birthdays ?? [];
  const hasSelectedOverflow =
    previewTasks.some(
      (item) => item.would_exceed_limit && selectedTasks.includes(item.id),
    ) ||
    previewBirthdays.some(
      (item) => item.would_exceed_limit && selectedBirthdays.includes(item.id),
    );
  const canConfirmRestore =
    preview?.status === "preview" &&
    preview.label !== undefined &&
    preview.can_restore === true &&
    !restoreNeedsReview &&
    !hasSelectedOverflow;
  const visibleOrphanedDrafts = Object.values(orphanedDrafts).filter(
    (orphan) => orphan.slug === slug,
  );
  const blockedByTombstoneCapacity = preview?.reasons?.some(
    (reason) =>
      reason === "task_recovery_limit" || reason === "birthday_recovery_limit",
  );

  return (
    <>
      <Modal
        open={open}
        onClose={handleClose}
        title="Etiquetas del tablero"
        fullScreenMobile
      >
        <div className="space-y-5">
          <p className="text-sm text-text-secondary">
            El catálogo es privado de este tablero. Podés crear hasta 100
            etiquetas y asignar hasta 10 a cada tarea o cumpleaños.
          </p>
          {notice ? (
            <output
              className="block text-sm text-status-connected"
              aria-live="polite"
            >
              {notice}
            </output>
          ) : null}
          {error ? (
            <div className="space-y-2">
              <p
                id={errorId}
                className="text-priority-urgent text-sm"
                role="alert"
              >
                {error}
              </p>
              {catalogReadFailed ? (
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  onClick={() => void retryCatalogRead()}
                  disabled={loading}
                >
                  Reintentar lectura del catálogo
                </Button>
              ) : null}
            </div>
          ) : null}

          <form
            onSubmit={(event) => void createLabel(event)}
            className="space-y-2 rounded-lg border border-border bg-surface-base p-3"
          >
            <label
              htmlFor={nameId}
              className="block font-medium text-sm text-text-primary"
            >
              Nueva etiqueta
            </label>
            <div className="flex flex-col gap-2 sm:flex-row">
              <input
                id={nameId}
                value={newName}
                onChange={(event) => setNewName(event.target.value)}
                maxLength={40}
                aria-describedby={error ? errorId : undefined}
                aria-invalid={Boolean(error)}
                placeholder="Nombre"
                className="h-10 min-w-0 flex-1 rounded-md border border-border bg-surface-raised px-3 text-sm text-text-primary outline-none focus:border-accent focus:ring-1 focus:ring-accent"
              />
              <label className="sr-only" htmlFor={`${nameId}-color`}>
                Color de la nueva etiqueta
              </label>
              <select
                id={`${nameId}-color`}
                value={newColor}
                onChange={(event) =>
                  setNewColor(event.target.value as BoardLabelColor)
                }
                className="h-10 rounded-md border border-border bg-surface-raised px-2 text-sm text-text-primary"
              >
                {colors.map((color) => (
                  <option key={color.value} value={color.value}>
                    {color.label}
                  </option>
                ))}
              </select>
              <Button
                type="submit"
                disabled={loading || labels.length >= 100 || !newName.trim()}
              >
                <IconTag size={15} aria-hidden="true" />
                Crear
              </Button>
            </div>
            <p className="text-text-muted text-xs">
              {labels.length} de 100 etiquetas activas · hasta 40 caracteres.
            </p>
          </form>

          {loading && labels.length === 0 ? (
            <p className="text-sm text-text-muted" aria-live="polite">
              Cargando etiquetas…
            </p>
          ) : labels.length === 0 ? (
            <p className="text-sm text-text-muted">
              Todavía no hay etiquetas activas.
            </p>
          ) : (
            <ul className="space-y-2" aria-label="Etiquetas activas">
              {labels.map((label) => {
                const draft = drafts[label.id] ?? createBoardLabelDraft(label);
                const changed = isBoardLabelDraftDirty(draft);
                const conflict = labelConflicts[label.id];
                return (
                  <li
                    key={label.id}
                    className="flex flex-col gap-2 rounded-lg border border-border bg-surface-base p-3 sm:flex-row sm:flex-wrap sm:items-center"
                  >
                    <label
                      className="sr-only"
                      htmlFor={`label-name-${label.id}`}
                    >
                      Nombre de {label.name}
                    </label>
                    <input
                      id={`label-name-${label.id}`}
                      value={draft.name}
                      onChange={(event) =>
                        setDrafts((current) => ({
                          ...current,
                          [label.id]: {
                            ...draft,
                            name: event.target.value,
                          },
                        }))
                      }
                      maxLength={40}
                      disabled={loading || Boolean(conflict)}
                      className="h-10 min-w-0 flex-1 rounded-md border border-border bg-surface-raised px-3 text-sm text-text-primary"
                    />
                    <label
                      className="sr-only"
                      htmlFor={`label-color-${label.id}`}
                    >
                      Color de {label.name}
                    </label>
                    <select
                      id={`label-color-${label.id}`}
                      value={draft.color}
                      onChange={(event) =>
                        setDrafts((current) => ({
                          ...current,
                          [label.id]: {
                            ...draft,
                            color: event.target.value as BoardLabelColor,
                          },
                        }))
                      }
                      className="h-10 rounded-md border border-border bg-surface-raised px-2 text-sm text-text-primary"
                      disabled={loading || Boolean(conflict)}
                    >
                      {colors.map((color) => (
                        <option key={color.value} value={color.value}>
                          {color.label}
                        </option>
                      ))}
                    </select>
                    <div className="flex items-center justify-end gap-1">
                      <Button
                        size="sm"
                        onClick={() => void saveLabel(label)}
                        disabled={
                          loading ||
                          Boolean(conflict) ||
                          !changed ||
                          !draft.name.trim()
                        }
                      >
                        Guardar
                      </Button>
                      {role === "owner" ? (
                        <Button
                          size="sm"
                          variant="danger"
                          onClick={() => setDeleteTarget(label)}
                          disabled={loading}
                          aria-label={`Eliminar etiqueta ${label.name}`}
                          title="Eliminar etiqueta"
                        >
                          <IconTrash size={15} aria-hidden="true" />
                        </Button>
                      ) : null}
                    </div>
                    {conflict ? (
                      <section
                        className="w-full basis-full space-y-2 rounded-md border border-priority-medium/40 p-3 text-sm"
                        aria-label={`Conflicto de versión de ${label.name}`}
                      >
                        <p>
                          Tu edición: “{conflict.proposal.name}”, color{" "}
                          {colors.find(
                            (color) => color.value === conflict.proposal.color,
                          )?.label ?? conflict.proposal.color}
                          .
                        </p>
                        <p>
                          Versión actual: “{conflict.current.name}”, color{" "}
                          {colors.find(
                            (color) => color.value === conflict.current.color,
                          )?.label ?? conflict.current.color}
                          , versión {conflict.current.version}.
                        </p>
                        <div className="flex flex-wrap justify-end gap-2">
                          <Button
                            size="sm"
                            variant="ghost"
                            onClick={() =>
                              resolveLabelVersionConflict(
                                label.id,
                                "use_current",
                              )
                            }
                          >
                            Usar versión actual
                          </Button>
                          <Button
                            size="sm"
                            onClick={() =>
                              resolveLabelVersionConflict(
                                label.id,
                                "keep_draft",
                              )
                            }
                          >
                            Revisar mis cambios
                          </Button>
                        </div>
                      </section>
                    ) : null}
                  </li>
                );
              })}
            </ul>
          )}

          {visibleOrphanedDrafts.length > 0 ? (
            <section
              aria-labelledby="orphaned-label-drafts-title"
              className="space-y-3 border-border border-t pt-4"
              aria-live="polite"
            >
              <h3
                id="orphaned-label-drafts-title"
                className="font-semibold text-sm text-text-primary"
              >
                Borradores de etiquetas ya no disponibles
              </h3>
              {visibleOrphanedDrafts.map(({ label, draft }) => (
                <div
                  key={label.id}
                  className="space-y-2 rounded-lg border border-border bg-surface-base p-3 text-sm"
                >
                  <p>Etiqueta ya no disponible: “{label.name}”.</p>
                  <p>
                    Tu borrador local: “{draft.name}”, color{" "}
                    {colors.find((color) => color.value === draft.color)
                      ?.label ?? draft.color}
                    . No se reenviará automáticamente.
                  </p>
                  <div className="flex justify-end">
                    <Button
                      size="sm"
                      variant="ghost"
                      onClick={() => discardOrphanedDraft(label.id)}
                    >
                      Descartar borrador
                    </Button>
                  </div>
                </div>
              ))}
            </section>
          ) : null}

          {role === "owner" ? (
            <section
              aria-labelledby="deleted-labels-title"
              className="space-y-3 border-border border-t pt-4"
            >
              <h3
                id="deleted-labels-title"
                className="font-semibold text-sm text-text-primary"
              >
                Papelera de etiquetas
              </h3>
              {trash.length === 0 ? (
                <p className="text-sm text-text-muted">
                  No hay etiquetas recuperables.
                </p>
              ) : (
                <ul className="space-y-2">
                  {trash.map((label) => (
                    <li
                      key={label.id}
                      className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-border bg-surface-base p-3"
                    >
                      <div>
                        <span className="font-medium text-sm text-text-primary">
                          {label.name}
                        </span>
                        <span className="ml-2 text-text-muted text-xs">
                          Vence {expirationLabel(label.expires_at)}
                        </span>
                      </div>
                      <Button
                        size="sm"
                        onClick={() => void loadPreview(label, label.name)}
                        disabled={loading}
                      >
                        Ver opciones de recuperación
                      </Button>
                    </li>
                  ))}
                </ul>
              )}
              {restoreTarget && preview ? (
                <section
                  className="space-y-3 rounded-lg border border-accent/40 bg-surface-base p-3"
                  aria-labelledby="label-restore-title"
                >
                  <h4
                    id="label-restore-title"
                    className="font-semibold text-sm text-text-primary"
                  >
                    Vista previa de recuperación: {restoreTarget.name}
                  </h4>
                  <div className="flex flex-col gap-2 sm:flex-row sm:items-end">
                    <label className="min-w-0 flex-1 space-y-1 text-text-secondary text-xs">
                      Nombre para recuperar
                      <input
                        value={restoreName}
                        onChange={(event) => setRestoreName(event.target.value)}
                        maxLength={40}
                        className="h-10 w-full rounded-md border border-border bg-surface-raised px-3 text-sm text-text-primary"
                      />
                    </label>
                    <Button
                      size="sm"
                      onClick={() =>
                        void loadPreview(restoreTarget, restoreName, {
                          preserveSelections: true,
                          requireReview: restoreNeedsReview,
                        })
                      }
                      disabled={loading || !restoreName.trim()}
                    >
                      Actualizar vista previa
                    </Button>
                  </div>
                  {preview.status === "preview" && !preview.can_restore ? (
                    <output className="block text-priority-medium text-sm">
                      {blockedByTombstoneCapacity
                        ? "Recupera primero desde Series las tareas o cumpleaños en papelera que tenían esta etiqueta. Luego actualiza la vista previa y desmarca cualquier elemento que ya tenga 10 etiquetas activas para omitir solo esa asociación."
                        : preview.reasons?.includes("duplicate_name")
                          ? "Ese nombre coincide con una etiqueta activa; elegí otro."
                          : "El tablero no tiene lugar libre. Eliminá una etiqueta activa y actualizá la vista previa."}
                    </output>
                  ) : null}
                  {preview.status === "expired" ? (
                    <p className="text-priority-urgent text-sm" role="alert">
                      Venció el plazo de recuperación de esta etiqueta.
                    </p>
                  ) : null}
                  {restoreNeedsReview && preview.label ? (
                    <section
                      className="space-y-2 rounded-md border border-priority-medium/40 p-3 text-sm"
                      aria-label="Revisión de versión de etiqueta"
                    >
                      <p>
                        Versión actual: “{preview.label.name}”, color{" "}
                        {colors.find(
                          (color) => color.value === preview.label?.color,
                        )?.label ?? preview.label.color}
                        , versión {preview.label.version}.
                      </p>
                      <p>Tu propuesta: recuperar como “{restoreName}”.</p>
                      <Button
                        size="sm"
                        onClick={() => void reviewRestoreVersion()}
                        disabled={loading}
                      >
                        Revisar estado actual y conservar mi propuesta
                      </Button>
                    </section>
                  ) : null}
                  <RestoreAssociationChoices
                    title="Tareas que tenían esta etiqueta"
                    items={previewTasks}
                    selectedIds={selectedTasks}
                    onChange={setSelectedTasks}
                    disabled={loading}
                  />
                  <RestoreAssociationChoices
                    title="Cumpleaños que tenían esta etiqueta"
                    items={previewBirthdays}
                    selectedIds={selectedBirthdays}
                    onChange={setSelectedBirthdays}
                    disabled={loading}
                  />
                  {hasSelectedOverflow ? (
                    <output className="block text-priority-medium text-sm">
                      Desmarcá cada elemento que ya tenga 10 etiquetas o libera
                      un lugar y actualizá la vista previa.
                    </output>
                  ) : null}
                  <div className="flex justify-end gap-2">
                    <Button
                      variant="ghost"
                      onClick={() => {
                        setRestoreTarget(null);
                        setPreview(null);
                      }}
                      disabled={loading}
                    >
                      Cancelar
                    </Button>
                    <Button
                      onClick={() => void confirmRestore()}
                      disabled={loading || !canConfirmRestore}
                    >
                      {loading ? "Recuperando…" : "Confirmar recuperación"}
                    </Button>
                  </div>
                </section>
              ) : null}
            </section>
          ) : null}
        </div>
      </Modal>

      <ConfirmDialog
        open={deleteTarget !== null}
        onClose={() => setDeleteTarget(null)}
        onConfirm={() => void confirmDelete()}
        title="Eliminar etiqueta"
        description={
          deleteTarget
            ? `Se ocultará “${deleteTarget.name}” y sus asociaciones quedarán guardadas. Podés recuperarla durante 7 días; después se purgarán.`
            : ""
        }
        confirmLabel="Eliminar etiqueta"
        cancelLabel="Cancelar"
        loading={loading}
      />
    </>
  );
}

function RestoreAssociationChoices({
  title,
  items,
  selectedIds,
  onChange,
  disabled,
}: {
  title: string;
  items: BoardLabelRestorePreview["associated_tasks"];
  selectedIds: string[];
  onChange: (ids: string[]) => void;
  disabled: boolean;
}) {
  const id = useId();
  return (
    <fieldset disabled={disabled} className="space-y-2">
      <legend className="font-medium text-sm text-text-primary">{title}</legend>
      {items.length === 0 ? (
        <p className="text-text-muted text-xs">
          No hay relaciones disponibles.
        </p>
      ) : (
        <div className="space-y-1">
          {items.map((item) => {
            const checked = selectedIds.includes(item.id);
            const checkboxId = `${id}-${item.id}`;
            const name = item.title ?? item.name ?? "Elemento sin nombre";
            return (
              <label
                key={item.id}
                htmlFor={checkboxId}
                className="flex items-start gap-2 rounded-md px-2 py-1.5 text-sm hover:bg-surface-hover"
              >
                <input
                  id={checkboxId}
                  type="checkbox"
                  checked={checked}
                  onChange={(event) => {
                    const next = new Set(selectedIds);
                    if (event.target.checked) next.add(item.id);
                    else next.delete(item.id);
                    onChange([...next]);
                  }}
                  className="mt-0.5 size-4 accent-accent"
                />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-text-primary">
                    {name}
                  </span>
                  <span className="block text-text-muted text-xs">
                    {item.active_label_count} de 10 etiquetas activas
                    {item.would_exceed_limit
                      ? " · supera el límite al incluir esta etiqueta"
                      : ""}
                  </span>
                </span>
              </label>
            );
          })}
        </div>
      )}
    </fieldset>
  );
}
