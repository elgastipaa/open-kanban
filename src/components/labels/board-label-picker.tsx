import { BoardLabelBadge } from "@/components/labels/board-label-badge";
import type { BoardLabel } from "@/lib/types";

export function BoardLabelPicker({
  labels,
  selectedIds,
  onChange,
  disabled = false,
  idPrefix,
  legend = "Etiquetas",
}: {
  labels: BoardLabel[];
  selectedIds: string[];
  onChange: (next: string[]) => void;
  disabled?: boolean;
  idPrefix: string;
  legend?: string;
}) {
  const selected = new Set(selectedIds);

  return (
    <fieldset disabled={disabled} className="space-y-2">
      <legend className="font-semibold text-sm text-text-primary">
        {legend}
      </legend>
      {labels.length === 0 ? (
        <p className="text-text-muted text-xs">
          No hay etiquetas activas en este tablero.
        </p>
      ) : (
        <div className="flex flex-wrap gap-2">
          {labels.map((label) => {
            const id = `${idPrefix}-${label.id}`;
            const checked = selected.has(label.id);
            const limitReached = selected.size >= 10 && !checked;
            return (
              <label
                key={label.id}
                htmlFor={id}
                className={`inline-flex cursor-pointer items-center gap-2 rounded-md border border-border px-2 py-1.5 text-sm ${limitReached ? "cursor-not-allowed opacity-50" : "hover:bg-surface-hover"}`}
              >
                <input
                  id={id}
                  type="checkbox"
                  checked={checked}
                  disabled={limitReached}
                  onChange={(event) => {
                    const next = new Set(selectedIds);
                    if (event.target.checked) next.add(label.id);
                    else next.delete(label.id);
                    onChange([...next]);
                  }}
                  className="size-4 accent-accent"
                />
                <BoardLabelBadge label={label} />
              </label>
            );
          })}
        </div>
      )}
      <p className="text-text-muted text-xs" aria-live="polite">
        {selected.size} de 10 etiquetas seleccionadas.
      </p>
    </fieldset>
  );
}
