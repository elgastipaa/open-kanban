"use client";

import { IconTag, IconTrash } from "@tabler/icons-react";
import { type FormEvent, useEffect, useId, useMemo, useState } from "react";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { Modal } from "@/components/ui/modal";
import {
  type BoardLabelRestorePreview,
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
  const [drafts, setDrafts] = useState<
    Record<string, { name: string; color: BoardLabelColor }>
  >({});
  const [newName, setNewName] = useState("");
  const [newColor, setNewColor] = useState<BoardLabelColor>("blue");
  const [deleteTarget, setDeleteTarget] = useState<BoardLabel | null>(null);
  const [restoreTarget, setRestoreTarget] = useState<DeletedBoardLabel | null>(
    null,
  );
  const [preview, setPreview] = useState<BoardLabelRestorePreview | null>(null);
  const [restoreName, setRestoreName] = useState("");
  const [selectedTasks, setSelectedTasks] = useState<string[]>([]);
  const [selectedBirthdays, setSelectedBirthdays] = useState<string[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const nameId = useId();
  const errorId = useId();

  useEffect(() => {
    setDrafts(
      Object.fromEntries(
        labels.map((label) => [
          label.id,
          { name: label.name, color: label.color },
        ]),
      ),
    );
  }, [labels]);

  useEffect(() => {
    if (!open) return;
    let disposed = false;
    setError(null);
    setNotice(null);
    setLoading(true);
    Promise.all([
      listBoardLabels(supabase, slug),
      role === "owner"
        ? listDeletedBoardLabels(supabase, slug)
        : Promise.resolve([]),
    ])
      .then(([active, deleted]) => {
        if (disposed) return;
        onLabelsChange(active);
        setTrash(deleted);
      })
      .catch(() => {
        if (!disposed) setError("No se pudo cargar el catálogo de etiquetas.");
      })
      .finally(() => {
        if (!disposed) setLoading(false);
      });
    return () => {
      disposed = true;
    };
  }, [onLabelsChange, open, role, slug, supabase]);

  async function refreshCatalog() {
    const active = await listBoardLabels(supabase, slug);
    onLabelsChange(active);
    setTrash(
      role === "owner" ? await listDeletedBoardLabels(supabase, slug) : [],
    );
    await onChanged();
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
        setError(resultMessage(result.status, result.reason));
        return;
      }
      setNewName("");
      setNotice("Se creó la etiqueta.");
      await refreshCatalog();
    } catch {
      setError("No se pudo crear la etiqueta. Conservamos el nombre escrito.");
    } finally {
      setLoading(false);
    }
  }

  async function saveLabel(label: BoardLabel) {
    const draft = drafts[label.id];
    if (!draft || loading) return;
    setLoading(true);
    setError(null);
    setNotice(null);
    try {
      const result = await updateBoardLabel(supabase, {
        slug,
        labelId: label.id,
        expectedVersion: label.version,
        name: draft.name,
        color: draft.color,
      });
      if (result.status !== "confirmed") {
        setError(resultMessage(result.status, result.reason));
        await refreshCatalog();
        return;
      }
      setNotice("Se guardaron el nombre y el color.");
      await refreshCatalog();
    } catch {
      setError(
        "No se pudo guardar la etiqueta. Conservamos los cambios escritos.",
      );
    } finally {
      setLoading(false);
    }
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
        setError(resultMessage(result.status, result.reason));
        await refreshCatalog();
        return;
      }
      setDeleteTarget(null);
      setNotice(
        "La etiqueta quedó oculta y se puede recuperar durante 7 días.",
      );
      await refreshCatalog();
    } catch {
      setError("No se pudo confirmar el borrado de la etiqueta.");
    } finally {
      setLoading(false);
    }
  }

  async function loadPreview(label: DeletedBoardLabel, name = restoreName) {
    setLoading(true);
    setError(null);
    try {
      const next = await previewRestoreBoardLabel(supabase, {
        slug,
        labelId: label.id,
        name,
      });
      setRestoreTarget(label);
      setRestoreName(name);
      setPreview(next);
      if (next.status === "preview") {
        setSelectedTasks(next.associated_tasks.map((item) => item.id));
        setSelectedBirthdays(next.associated_birthdays.map((item) => item.id));
      } else if (next.status === "expired") {
        setError(resultMessage("expired"));
      }
    } catch {
      setError("No se pudo preparar la vista previa de recuperación.");
    } finally {
      setLoading(false);
    }
  }

  async function confirmRestore() {
    if (!restoreTarget || !preview || !canConfirmRestore || loading) return;
    setLoading(true);
    setError(null);
    setNotice(null);
    try {
      const result = await restoreBoardLabel(supabase, {
        slug,
        labelId: restoreTarget.id,
        expectedVersion: restoreTarget.version,
        name: restoreName,
        taskIds: selectedTasks,
        birthdayIds: selectedBirthdays,
      });
      if (result.status !== "confirmed") {
        setError(resultMessage(result.status, result.reason));
        await loadPreview(restoreTarget, restoreName);
        return;
      }
      setRestoreTarget(null);
      setPreview(null);
      setNotice("Se recuperó la etiqueta y las relaciones elegidas.");
      await refreshCatalog();
    } catch {
      setError(
        "No se pudo confirmar la recuperación. Revisá la vista previa e intentá de nuevo.",
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
    preview.can_restore === true &&
    !hasSelectedOverflow;
  const blockedByTombstoneCapacity = preview?.reasons?.some(
    (reason) =>
      reason === "task_recovery_limit" || reason === "birthday_recovery_limit",
  );

  return (
    <>
      <Modal
        open={open}
        onClose={onClose}
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
            <p
              id={errorId}
              className="text-priority-urgent text-sm"
              role="alert"
            >
              {error}
            </p>
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
                const draft = drafts[label.id] ?? {
                  name: label.name,
                  color: label.color,
                };
                const changed =
                  draft.name !== label.name || draft.color !== label.color;
                return (
                  <li
                    key={label.id}
                    className="flex flex-col gap-2 rounded-lg border border-border bg-surface-base p-3 sm:flex-row sm:items-center"
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
                          [label.id]: { ...draft, name: event.target.value },
                        }))
                      }
                      maxLength={40}
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
                        disabled={loading || !changed || !draft.name.trim()}
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
                  </li>
                );
              })}
            </ul>
          )}

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
                        void loadPreview(restoreTarget, restoreName)
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
