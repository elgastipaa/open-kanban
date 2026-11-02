"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  confirmSavedViewRestore,
  createSavedView,
  deleteSavedView,
  loadSavedViews,
  previewSavedViewRestore,
  updateSavedView,
} from "@/lib/saved-view-actions";
import {
  isSavedViewDefinition,
  resolveSavedViewConflict,
  type SavedView,
  type SavedViewContext,
  type SavedViewDefinition,
  type SavedViewMutationResult,
  type SavedViewReferenceField,
  type SavedViewRestorePreview,
  type SavedViewsSnapshot,
} from "@/lib/saved-view-state";

interface SavedViewsPanelProps {
  context: SavedViewContext;
  currentDefinition: SavedViewDefinition;
  initialSnapshot: SavedViewsSnapshot;
  onApply: (
    definition: SavedViewDefinition,
    invalidReferences?: SavedView["invalid_references"],
  ) => void;
}

function referenceLabel(field: SavedViewReferenceField): string {
  switch (field) {
    case "boardId":
      return "el tablero de alcance";
    case "filterBoardId":
      return "el tablero del filtro";
    case "labels":
      return "una o más etiquetas";
    case "assigneeId":
      return "el responsable";
  }
}

function restoreReason(reason: string): string {
  switch (reason) {
    case "active_limit":
      return "Ya hay 50 vistas activas. Elimina una antes de recuperar esta.";
    case "name_conflict":
      return "Ese nombre ya se usa en este contexto. Elige otro nombre.";
    case "invalid_references":
      return "Hay referencias que ya no están disponibles. Revisa los filtros antes de recuperar la vista.";
    default:
      return "No se puede recuperar esta vista con la propuesta actual.";
  }
}

function mutationMessage(result: SavedViewMutationResult): string {
  switch (result.status) {
    case "name_conflict":
      return "Ya existe una vista activa con ese nombre en este contexto.";
    case "limit_reached":
      return "Llegaste al límite de 50 vistas activas. Elimina una vista antes de guardar otra.";
    case "invalid_references":
      return `Revisa ${result.invalid_references.map(referenceLabel).join(", ")} antes de guardar.`;
    case "unavailable":
      return "La vista ya no está disponible con tu acceso actual.";
    case "expired":
      return "Terminó el plazo de recuperación de siete días.";
    case "conflict":
      return result.reason === "stale_version"
        ? "La vista cambió en otro dispositivo. Tu propuesta se conserva para revisarla."
        : restoreReason(result.reason);
    case "error":
      return "No se pudo guardar. Comprueba la conexión e inténtalo de nuevo.";
    default:
      return "";
  }
}

function replaceView(views: SavedView[], next: SavedView): SavedView[] {
  return views.map((view) => (view.id === next.id ? next : view));
}

export function SavedViewsPanel({
  context,
  currentDefinition,
  initialSnapshot,
  onApply,
}: SavedViewsPanelProps) {
  const [activeViews, setActiveViews] = useState<SavedView[]>(
    initialSnapshot.active_views ?? [],
  );
  const [deletedViews, setDeletedViews] = useState<SavedView[]>(
    initialSnapshot.deleted_views ?? [],
  );
  const [selectedId, setSelectedId] = useState(
    initialSnapshot.active_views?.[0]?.id ?? "",
  );
  const [deletedId, setDeletedId] = useState(
    initialSnapshot.deleted_views?.[0]?.id ?? "",
  );
  const [name, setName] = useState(
    initialSnapshot.active_views?.[0]?.name ?? "",
  );
  const [newName, setNewName] = useState("");
  const [restoreName, setRestoreName] = useState("");
  const [restoreDefinition, setRestoreDefinition] =
    useState<SavedViewDefinition | null>(
      initialSnapshot.deleted_views?.[0]?.definition ?? null,
    );
  const [preview, setPreview] = useState<SavedViewRestorePreview | null>(null);
  const [updateConflict, setUpdateConflict] = useState<SavedView | null>(null);
  const [restoreConflict, setRestoreConflict] = useState<SavedView | null>(
    null,
  );
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState(
    initialSnapshot.status === "error"
      ? "No se pudieron cargar las vistas guardadas. Puedes reintentar."
      : "",
  );
  const [accessUnavailable, setAccessUnavailable] = useState(
    initialSnapshot.status === "unavailable",
  );
  const clearPrivateViewState = useCallback(() => {
    setActiveViews([]);
    setDeletedViews([]);
    setSelectedId("");
    setDeletedId("");
    setName("");
    setNewName("");
    setRestoreName("");
    setRestoreDefinition(null);
    setPreview(null);
    setUpdateConflict(null);
    setRestoreConflict(null);
    setConfirmDelete(false);
  }, []);
  const selectedView = useMemo(
    () => activeViews.find((view) => view.id === selectedId) ?? null,
    [activeViews, selectedId],
  );
  const selectedDeletedView = useMemo(
    () => deletedViews.find((view) => view.id === deletedId) ?? null,
    [deletedId, deletedViews],
  );
  const currentDefinitionValid = isSavedViewDefinition(
    context,
    currentDefinition,
  );

  useEffect(() => {
    if (initialSnapshot.status === "available") {
      setActiveViews(initialSnapshot.active_views ?? []);
      setDeletedViews(initialSnapshot.deleted_views ?? []);
      setSelectedId((current) =>
        initialSnapshot.active_views?.some((view) => view.id === current)
          ? current
          : (initialSnapshot.active_views?.[0]?.id ?? ""),
      );
      const selectedActive =
        initialSnapshot.active_views?.find((view) => view.id === selectedId) ??
        initialSnapshot.active_views?.[0];
      if (selectedActive && selectedActive.id !== selectedId) {
        setName(selectedActive.name);
      }
      setDeletedId((current) =>
        initialSnapshot.deleted_views?.some((view) => view.id === current)
          ? current
          : (initialSnapshot.deleted_views?.[0]?.id ?? ""),
      );
      const deletedView =
        initialSnapshot.deleted_views?.find((view) => view.id === deletedId) ??
        initialSnapshot.deleted_views?.[0];
      if (deletedView) {
        setRestoreName(deletedView.name);
        setRestoreDefinition(deletedView.definition);
      }
      setAccessUnavailable(false);
      return;
    }
    if (initialSnapshot.status === "unavailable") {
      clearPrivateViewState();
      setAccessUnavailable(true);
    }
  }, [clearPrivateViewState, deletedId, initialSnapshot, selectedId]);

  const refresh = useCallback(async () => {
    setBusy(true);
    try {
      const snapshot = await loadSavedViews(context);
      if (snapshot.status === "unavailable") {
        clearPrivateViewState();
        setAccessUnavailable(true);
        setMessage("Ya no tienes acceso a estas vistas guardadas.");
        return false;
      }
      if (snapshot.status !== "available") {
        setMessage("No se pudieron actualizar las vistas. Puedes reintentar.");
        return false;
      }
      setActiveViews(snapshot.active_views ?? []);
      setDeletedViews(snapshot.deleted_views ?? []);
      setSelectedId((current) =>
        snapshot.active_views?.some((view) => view.id === current)
          ? current
          : (snapshot.active_views?.[0]?.id ?? ""),
      );
      if (!snapshot.active_views?.some((view) => view.id === selectedId)) {
        setName(snapshot.active_views?.[0]?.name ?? "");
      }
      setDeletedId((current) =>
        snapshot.deleted_views?.some((view) => view.id === current)
          ? current
          : (snapshot.deleted_views?.[0]?.id ?? ""),
      );
      if (!snapshot.deleted_views?.some((view) => view.id === deletedId)) {
        const nextDeleted = snapshot.deleted_views?.[0];
        setRestoreName(nextDeleted?.name ?? "");
        setRestoreDefinition(nextDeleted?.definition ?? null);
        setPreview(null);
        setRestoreConflict(null);
      }
      setAccessUnavailable(false);
      setMessage("");
      return true;
    } catch {
      setMessage("No se pudieron actualizar las vistas. Puedes reintentar.");
      return false;
    } finally {
      setBusy(false);
    }
  }, [clearPrivateViewState, context, deletedId, selectedId]);

  async function handleCreate() {
    if (!currentDefinitionValid || !newName.trim() || busy || accessUnavailable)
      return;
    setBusy(true);
    setMessage("");
    try {
      const result = await createSavedView(context, newName, currentDefinition);
      if (result.status === "saved") {
        setSelectedId(result.view.id);
        setName(result.view.name);
        setNewName("");
        setMessage(
          "Vista guardada. Los filtros y el orden se conservan para este contexto.",
        );
        await refresh();
        return;
      }
      setMessage(mutationMessage(result));
      if (result.status === "unavailable") {
        clearPrivateViewState();
        setAccessUnavailable(true);
      }
    } catch {
      setMessage(
        "No se pudo guardar la vista. Comprueba la conexión e inténtalo de nuevo.",
      );
    } finally {
      setBusy(false);
    }
  }

  async function handleUpdate() {
    if (!selectedView || !currentDefinitionValid || busy || accessUnavailable)
      return;
    setBusy(true);
    setMessage("");
    try {
      const result = await updateSavedView(
        context,
        selectedView.id,
        selectedView.version,
        name,
        currentDefinition,
      );
      if (result.status === "saved") {
        setActiveViews((current) => replaceView(current, result.view));
        setUpdateConflict(null);
        setMessage("Vista actualizada de forma explícita.");
        return;
      }
      if (
        result.status === "conflict" &&
        result.reason === "stale_version" &&
        result.view
      ) {
        setUpdateConflict(result.view);
        setMessage(mutationMessage(result));
        return;
      }
      setMessage(mutationMessage(result));
      if (result.status === "unavailable") {
        clearPrivateViewState();
        setAccessUnavailable(true);
      }
    } catch {
      setMessage(
        "No se pudo actualizar la vista. Tu búsqueda actual se conserva.",
      );
    } finally {
      setBusy(false);
    }
  }

  function resolveUpdateConflict(choice: "use_current" | "keep_local") {
    if (!updateConflict) return;
    const resolution = resolveSavedViewConflict(
      { current: updateConflict, localDefinition: currentDefinition },
      choice,
    );
    setActiveViews((current) => replaceView(current, updateConflict));
    setSelectedId(updateConflict.id);
    setUpdateConflict(null);
    if (choice === "use_current") {
      setName(updateConflict.name);
      onApply(resolution.definition);
      setMessage("Se cargó la versión actual. Revísala antes de guardar.");
    } else {
      setMessage(
        "Tu variación se conserva. Revisa y pulsa Actualizar vista para enviarla con la versión actual.",
      );
    }
  }

  async function handleDelete() {
    if (!selectedView || busy || !confirmDelete) return;
    setBusy(true);
    setMessage("");
    try {
      const result = await deleteSavedView(
        context,
        selectedView.id,
        selectedView.version,
      );
      setConfirmDelete(false);
      if (result.status === "deleted") {
        setMessage("Vista eliminada. Puedes recuperarla durante siete días.");
        await refresh();
        return;
      }
      if (
        result.status === "conflict" &&
        result.reason === "stale_version" &&
        result.view
      ) {
        setActiveViews((current) =>
          replaceView(current, result.view as SavedView),
        );
      }
      setMessage(mutationMessage(result));
      if (result.status === "unavailable") {
        clearPrivateViewState();
        setAccessUnavailable(true);
      }
    } catch {
      setConfirmDelete(false);
      setMessage("No se pudo eliminar la vista. Inténtalo de nuevo.");
    } finally {
      setBusy(false);
    }
  }

  async function handlePreviewRestore(definition = restoreDefinition) {
    if (!selectedDeletedView || !definition || busy || accessUnavailable)
      return;
    setBusy(true);
    setMessage("");
    setRestoreDefinition(definition);
    try {
      const result = await previewSavedViewRestore(
        context,
        selectedDeletedView.id,
        restoreName,
        definition,
      );
      setPreview(result);
      if (result.status === "unavailable") {
        setMessage("La vista ya no está disponible con tu acceso actual.");
        await refresh();
      } else if (result.status === "expired") {
        setMessage("Terminó el plazo de recuperación de siete días.");
        await refresh();
      } else if (result.status === "error") {
        setMessage(
          "No se pudo actualizar la previsualización. Puedes reintentar.",
        );
      } else if (result.status === "preview" && !result.can_restore) {
        setMessage(
          "La propuesta necesita cambios antes de confirmar la recuperación.",
        );
      }
    } catch {
      setMessage(
        "No se pudo previsualizar la recuperación. Inténtalo de nuevo.",
      );
    } finally {
      setBusy(false);
    }
  }

  async function handleConfirmRestore() {
    if (
      !selectedDeletedView ||
      !preview ||
      preview.status !== "preview" ||
      preview.can_restore !== true ||
      !restoreDefinition ||
      busy
    ) {
      return;
    }
    setBusy(true);
    setMessage("");
    try {
      const result = await confirmSavedViewRestore(
        context,
        selectedDeletedView,
        restoreName,
        restoreDefinition,
      );
      if (result.status === "restored") {
        setPreview(null);
        setRestoreConflict(null);
        setMessage("Vista recuperada. No se aplicó a la búsqueda actual.");
        await refresh();
        return;
      }
      if (
        result.status === "conflict" &&
        result.reason === "stale_version" &&
        result.view
      ) {
        setRestoreConflict(result.view);
        setMessage(
          "La vista cambió en otro dispositivo. Tu propuesta de recuperación se conserva; revisa la versión actual antes de volver a previsualizar.",
        );
        return;
      }
      if (result.status === "invalid_references") {
        setPreview({
          status: "preview",
          can_restore: false,
          reasons: ["invalid_references"],
          invalid_references: result.invalid_references,
          view: result.view,
        });
      }
      setMessage(mutationMessage(result));
      if (result.status === "unavailable") {
        clearPrivateViewState();
        setAccessUnavailable(true);
      } else {
        await refresh();
      }
    } catch {
      setMessage("No se pudo recuperar la vista. Tu propuesta se conserva.");
    } finally {
      setBusy(false);
    }
  }

  function acceptRestoreConflict() {
    if (!restoreConflict) return;
    setDeletedViews((current) => replaceView(current, restoreConflict));
    setDeletedId(restoreConflict.id);
    setRestoreName(restoreConflict.name);
    setRestoreConflict(null);
    setPreview(null);
    setMessage(
      "Se cargó la versión actual. Tu propuesta sigue en el formulario; vuelve a previsualizarla para confirmar.",
    );
  }

  const panelTitle =
    context === "search" ? "Vistas de búsqueda" : "Vistas de Mis tareas";

  return (
    <section
      aria-labelledby={`saved-views-${context}-heading`}
      className="mb-6 rounded-2xl border border-border bg-surface-raised p-4 sm:p-5"
    >
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2
            id={`saved-views-${context}-heading`}
            className="font-semibold text-base"
          >
            {panelTitle}
          </h2>
          <p className="mt-1 text-sm text-text-secondary">
            Guarda filtros y orden personales. Los resultados siempre se
            calculan con tus permisos actuales.
          </p>
        </div>
        <button
          type="button"
          onClick={() => void refresh()}
          disabled={busy}
          className="rounded-lg border border-border px-3 py-2 text-sm hover:bg-surface-hover disabled:opacity-50"
        >
          Actualizar lista
        </button>
      </div>

      {message ? (
        <output
          className="mt-3 block rounded-lg border border-border bg-surface-base p-3 text-sm"
          aria-live="polite"
        >
          {message}
        </output>
      ) : null}
      {accessUnavailable ? (
        <output className="mt-3 block text-sm text-text-secondary">
          Las vistas guardadas no están disponibles. Se quitaron de esta
          pantalla los datos privados cargados.
        </output>
      ) : (
        <div className="mt-4 grid gap-5 lg:grid-cols-2">
          <div className="space-y-3">
            <label
              className="block font-medium text-sm"
              htmlFor={`saved-view-active-${context}`}
            >
              Vistas activas
            </label>
            <select
              id={`saved-view-active-${context}`}
              value={selectedId}
              onChange={(event) => {
                const nextId = event.target.value;
                setSelectedId(nextId);
                setName(
                  activeViews.find((view) => view.id === nextId)?.name ?? "",
                );
                setUpdateConflict(null);
                setConfirmDelete(false);
              }}
              className="min-h-11 w-full rounded-lg border border-border bg-surface-base px-3 text-sm"
            >
              <option value="">Elige una vista</option>
              {activeViews.map((view) => (
                <option key={view.id} value={view.id}>
                  {view.name}
                  {view.needs_review ? " · Revisión pendiente" : ""}
                </option>
              ))}
            </select>
            {selectedView ? (
              <>
                {selectedView.needs_review ? (
                  <output className="block rounded-lg border border-priority-medium/30 bg-priority-medium/10 p-3 text-sm">
                    Esta definición necesita revisión. Cárgala para corregir sus
                    condiciones y guárdala explícitamente antes de aplicarla.
                  </output>
                ) : null}
                <div className="flex flex-wrap gap-2">
                  <button
                    type="button"
                    onClick={() => onApply(selectedView.definition)}
                    disabled={selectedView.needs_review || busy}
                    className="rounded-lg bg-accent px-3 py-2 font-medium text-accent-foreground text-sm disabled:opacity-50"
                  >
                    Restablecer vista
                  </button>
                  {selectedView.needs_review ? (
                    <button
                      type="button"
                      onClick={() =>
                        onApply(
                          selectedView.definition,
                          selectedView.invalid_references,
                        )
                      }
                      disabled={busy}
                      className="rounded-lg border border-border px-3 py-2 text-sm hover:bg-surface-hover disabled:opacity-50"
                    >
                      Revisar definición
                    </button>
                  ) : null}
                </div>
                <label
                  className="block pt-2 font-medium text-sm"
                  htmlFor={`saved-view-name-${context}`}
                >
                  Nombre de la vista
                </label>
                <input
                  id={`saved-view-name-${context}`}
                  value={name}
                  onChange={(event) => setName(event.target.value)}
                  maxLength={60}
                  className="min-h-11 w-full rounded-lg border border-border bg-surface-base px-3 text-sm"
                />
                <div className="flex flex-wrap gap-2">
                  <button
                    type="button"
                    onClick={() => void handleUpdate()}
                    disabled={busy || !currentDefinitionValid || !name.trim()}
                    className="rounded-lg border border-border px-3 py-2 text-sm hover:bg-surface-hover disabled:opacity-50"
                  >
                    {selectedView.needs_review
                      ? "Confirmar revisión y actualizar"
                      : "Actualizar vista"}
                  </button>
                  {confirmDelete ? (
                    <>
                      <button
                        type="button"
                        onClick={() => void handleDelete()}
                        disabled={busy}
                        className="rounded-lg border border-priority-urgent/50 px-3 py-2 text-priority-urgent text-sm disabled:opacity-50"
                      >
                        Confirmar eliminación
                      </button>
                      <button
                        type="button"
                        onClick={() => setConfirmDelete(false)}
                        disabled={busy}
                        className="rounded-lg border border-border px-3 py-2 text-sm"
                      >
                        Cancelar
                      </button>
                    </>
                  ) : (
                    <button
                      type="button"
                      onClick={() => setConfirmDelete(true)}
                      disabled={busy}
                      className="rounded-lg border border-border px-3 py-2 text-sm text-text-secondary hover:bg-surface-hover disabled:opacity-50"
                    >
                      Eliminar vista…
                    </button>
                  )}
                </div>
                {updateConflict ? (
                  <div className="rounded-lg border border-priority-medium/30 bg-priority-medium/10 p-3 text-sm">
                    <p>
                      Versión actual del servidor: «{updateConflict.name}». Tu
                      búsqueda local se mantiene aparte.
                    </p>
                    <div className="mt-3 flex flex-wrap gap-2">
                      <button
                        type="button"
                        onClick={() => resolveUpdateConflict("use_current")}
                        className="rounded-lg border border-border px-3 py-2"
                      >
                        Usar versión actual
                      </button>
                      <button
                        type="button"
                        onClick={() => resolveUpdateConflict("keep_local")}
                        className="rounded-lg border border-border px-3 py-2"
                      >
                        Revisar y conservar mi variación
                      </button>
                    </div>
                  </div>
                ) : null}
              </>
            ) : null}
            <div className="border-border border-t pt-3">
              <label
                className="block font-medium text-sm"
                htmlFor={`saved-view-new-name-${context}`}
              >
                Guardar búsqueda actual como nueva
              </label>
              <div className="mt-2 flex flex-col gap-2 sm:flex-row">
                <input
                  id={`saved-view-new-name-${context}`}
                  value={newName}
                  onChange={(event) => setNewName(event.target.value)}
                  maxLength={60}
                  placeholder="Nombre de la vista"
                  className="min-h-11 min-w-0 flex-1 rounded-lg border border-border bg-surface-base px-3 text-sm"
                />
                <button
                  type="button"
                  onClick={() => void handleCreate()}
                  disabled={busy || !currentDefinitionValid || !newName.trim()}
                  className="min-h-11 rounded-lg border border-border px-3 text-sm hover:bg-surface-hover disabled:opacity-50"
                >
                  Guardar como nueva
                </button>
              </div>
              <p className="mt-1 text-text-muted text-xs">
                Máximo 60 caracteres; hasta 50 vistas activas entre ambos
                contextos.
              </p>
            </div>
          </div>

          <div className="space-y-3 border-border border-t pt-4 lg:border-t-0 lg:border-l lg:pt-0 lg:pl-5">
            <label
              className="block font-medium text-sm"
              htmlFor={`saved-view-trash-${context}`}
            >
              Vistas eliminadas · recuperables durante siete días
            </label>
            <select
              id={`saved-view-trash-${context}`}
              value={deletedId}
              onChange={(event) => {
                const nextId = event.target.value;
                const nextView = deletedViews.find(
                  (view) => view.id === nextId,
                );
                setDeletedId(nextId);
                setRestoreName(nextView?.name ?? "");
                setRestoreDefinition(nextView?.definition ?? null);
                setPreview(null);
                setRestoreConflict(null);
              }}
              className="min-h-11 w-full rounded-lg border border-border bg-surface-base px-3 text-sm"
            >
              <option value="">Elige una vista eliminada</option>
              {deletedViews.map((view) => (
                <option key={view.id} value={view.id}>
                  {view.name}
                </option>
              ))}
            </select>
            {selectedDeletedView ? (
              <>
                <label
                  className="block font-medium text-sm"
                  htmlFor={`saved-view-restore-name-${context}`}
                >
                  Nombre al recuperar
                </label>
                <input
                  id={`saved-view-restore-name-${context}`}
                  value={restoreName}
                  onChange={(event) => {
                    setRestoreName(event.target.value);
                    setPreview(null);
                  }}
                  maxLength={60}
                  className="min-h-11 w-full rounded-lg border border-border bg-surface-base px-3 text-sm"
                />
                <div className="flex flex-wrap gap-2">
                  <button
                    type="button"
                    onClick={() => void handlePreviewRestore()}
                    disabled={busy || !restoreDefinition || !restoreName.trim()}
                    className="rounded-lg border border-border px-3 py-2 text-sm hover:bg-surface-hover disabled:opacity-50"
                  >
                    Previsualizar recuperación
                  </button>
                  <button
                    type="button"
                    onClick={() => void handlePreviewRestore(currentDefinition)}
                    disabled={busy || !currentDefinitionValid}
                    className="rounded-lg border border-border px-3 py-2 text-sm hover:bg-surface-hover disabled:opacity-50"
                  >
                    Usar filtros actuales y revisar
                  </button>
                </div>
                {preview?.status === "preview" ? (
                  <div className="rounded-lg border border-border bg-surface-base p-3 text-sm">
                    <p className="font-medium">
                      Previsualización de recuperación
                    </p>
                    <p className="mt-1 text-text-secondary">
                      {preview.can_restore
                        ? "La propuesta se puede recuperar. La vista quedará en la lista y no se aplicará a la consulta actual."
                        : "La propuesta no se puede confirmar hasta resolver sus condiciones."}
                    </p>
                    {preview.reasons?.length ? (
                      <ul className="mt-2 list-disc space-y-1 pl-5 text-text-secondary">
                        {preview.reasons.map((reason) => (
                          <li key={reason}>{restoreReason(reason)}</li>
                        ))}
                      </ul>
                    ) : null}
                    {preview.invalid_references?.length ? (
                      <p className="mt-2 text-text-secondary">
                        Referencias por revisar:{" "}
                        {preview.invalid_references
                          .map(referenceLabel)
                          .join(", ")}
                        .
                      </p>
                    ) : null}
                    <button
                      type="button"
                      onClick={() => void handleConfirmRestore()}
                      disabled={!preview.can_restore || busy}
                      className="mt-3 rounded-lg bg-accent px-3 py-2 font-medium text-accent-foreground disabled:opacity-50"
                    >
                      Confirmar recuperación
                    </button>
                  </div>
                ) : null}
                {restoreConflict ? (
                  <div className="rounded-lg border border-priority-medium/30 bg-priority-medium/10 p-3 text-sm">
                    <p>
                      Versión actual: «{restoreConflict.name}». La propuesta
                      local no se aplicó.
                    </p>
                    <button
                      type="button"
                      onClick={acceptRestoreConflict}
                      className="mt-2 rounded-lg border border-border px-3 py-2"
                    >
                      Revisar versión actual y volver a previsualizar
                    </button>
                  </div>
                ) : null}
              </>
            ) : null}
          </div>
        </div>
      )}
    </section>
  );
}
