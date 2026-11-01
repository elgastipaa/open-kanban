"use client";

import { IconPlus } from "@tabler/icons-react";
import { motion } from "motion/react";
import { useEffect, useRef, useState } from "react";

interface AddColumnProps {
  onAdd: (title: string) => void;
  variant?: "desktop" | "empty";
  openSignal?: number;
}

interface AddColumnFormProps {
  onAdd: (title: string) => void;
  onCancel?: () => void;
  autoFocus?: boolean;
}

export function AddColumnForm({
  onAdd,
  onCancel,
  autoFocus = true,
}: AddColumnFormProps) {
  const [title, setTitle] = useState("");
  const [error, setError] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (autoFocus) inputRef.current?.focus();
  }, [autoFocus]);

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const trimmed = title.trim();
    if (!trimmed) {
      setError("Escribe un nombre para la columna.");
      inputRef.current?.focus();
      return;
    }
    if (trimmed.length > 100) {
      setError("El nombre puede tener hasta 100 caracteres.");
      inputRef.current?.focus();
      return;
    }
    onAdd(trimmed);
    setTitle("");
    setError(null);
  }

  return (
    <form
      onSubmit={handleSubmit}
      className="w-full rounded-xl border border-border bg-surface-raised p-3"
      aria-label="Crear columna"
    >
      <label
        htmlFor="new-column-title"
        className="block font-medium text-sm text-text-primary"
      >
        Nombre de la columna
      </label>
      <input
        ref={inputRef}
        id="new-column-title"
        value={title}
        onChange={(event) => {
          setTitle(event.target.value);
          if (error) setError(null);
        }}
        maxLength={100}
        aria-required="true"
        aria-invalid={Boolean(error)}
        aria-describedby={error ? "new-column-error" : undefined}
        className="mt-2 min-h-11 w-full rounded-lg border border-border bg-surface-base px-3 py-2 text-text-primary outline-none focus:border-accent focus:ring-2 focus:ring-accent/20"
        placeholder="Por ejemplo, Ideas"
      />
      {error ? (
        <p
          id="new-column-error"
          className="mt-2 text-priority-urgent text-sm"
          role="alert"
        >
          {error}
        </p>
      ) : null}
      <div className="mt-3 flex justify-end gap-2">
        {onCancel ? (
          <button
            type="button"
            onClick={onCancel}
            className="min-h-10 rounded-lg px-3 py-2 text-sm text-text-secondary hover:bg-surface-overlay"
          >
            Cancelar
          </button>
        ) : null}
        <button
          type="submit"
          className="min-h-10 rounded-lg bg-accent px-4 py-2 font-semibold text-sm text-text-primary hover:brightness-110"
        >
          Crear columna
        </button>
      </div>
    </form>
  );
}

export function AddColumn({
  onAdd,
  variant = "desktop",
  openSignal = 0,
}: AddColumnProps) {
  const [isOpen, setIsOpen] = useState(false);

  useEffect(() => {
    if (openSignal > 0) setIsOpen(true);
  }, [openSignal]);

  if (isOpen) {
    return (
      <div
        className={
          variant === "desktop" ? "w-[280px] shrink-0" : "w-full max-w-md"
        }
      >
        <AddColumnForm
          onAdd={(title) => {
            onAdd(title);
            setIsOpen(false);
          }}
          onCancel={() => setIsOpen(false)}
        />
      </div>
    );
  }

  if (variant === "empty") {
    return (
      <button
        type="button"
        onClick={() => setIsOpen(true)}
        className="inline-flex min-h-12 items-center justify-center gap-2 rounded-xl bg-accent px-5 py-3 font-semibold text-accent-foreground transition hover:bg-accent-hover focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent focus-visible:outline-offset-2"
      >
        <IconPlus size={18} aria-hidden="true" />
        Crear una columna
      </button>
    );
  }

  return (
    <motion.div
      layout
      transition={{ type: "spring", stiffness: 400, damping: 35, mass: 0.8 }}
      style={{ willChange: "transform" }}
      className="h-full shrink-0"
    >
      <button
        type="button"
        onClick={() => setIsOpen(true)}
        className="flex h-full w-12 min-w-12 shrink-0 cursor-pointer flex-col items-center rounded-xl border border-border border-dashed bg-surface-base py-4 text-sm text-text-muted transition-all hover:border-border-hover hover:bg-surface-raised hover:text-text-secondary"
        aria-label="Añadir columna"
      >
        <IconPlus size={18} className="mb-4 shrink-0" aria-hidden="true" />
        <div
          className="flex w-full flex-1 items-start justify-center overflow-hidden py-2"
          style={{ writingMode: "vertical-rl", transform: "rotate(180deg)" }}
        >
          <span className="-translate-x-1.5 whitespace-nowrap px-1 font-semibold">
            Añadir columna
          </span>
        </div>
      </button>
    </motion.div>
  );
}
