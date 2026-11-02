import { BoardLabelBadge } from "@/components/labels/board-label-badge";
import { Button } from "@/components/ui/button";
import type { BoardLabel } from "@/lib/types";

export function BoardLabelFilter({
  labels,
  selectedIds,
  onChange,
}: {
  labels: BoardLabel[];
  selectedIds: string[];
  onChange: (ids: string[]) => void;
}) {
  if (labels.length === 0) return null;
  const selected = new Set(selectedIds);

  return (
    <fieldset className="flex shrink-0 flex-wrap items-center gap-2 border-border border-b bg-surface-base px-4 py-2 md:px-6">
      <legend className="sr-only">Filtrar tarjetas por etiqueta</legend>
      <span className="font-medium text-text-secondary text-xs">
        Etiquetas:
      </span>
      {labels.map((label) => {
        const active = selected.has(label.id);
        return (
          <button
            key={label.id}
            type="button"
            aria-pressed={active}
            onClick={() => {
              const next = new Set(selectedIds);
              if (active) next.delete(label.id);
              else next.add(label.id);
              onChange([...next]);
            }}
            className={`rounded-full outline-none focus-visible:ring-2 focus-visible:ring-accent ${active ? "ring-2 ring-accent" : ""}`}
          >
            <BoardLabelBadge label={label} />
          </button>
        );
      })}
      <span className="sr-only" aria-live="polite">
        {selectedIds.length > 1
          ? "Se muestran tarjetas que tengan cualquiera de las etiquetas elegidas."
          : selectedIds.length === 1
            ? "Se muestran tarjetas con la etiqueta elegida."
            : "Se muestran todas las tarjetas."}
      </span>
      {selectedIds.length > 0 ? (
        <Button
          variant="ghost"
          size="sm"
          onClick={() => onChange([])}
          aria-label="Quitar filtro de etiquetas"
        >
          Limpiar filtro
        </Button>
      ) : null}
    </fieldset>
  );
}
