"use client";

import {
  IconDots,
  IconDownload,
  IconPencil,
  IconTrash,
  IconUpload,
  IconUsers,
  IconWorld,
} from "@tabler/icons-react";
import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import { BoardSignOutButton } from "@/components/auth/board-sign-out-button";
import { BoardTimeZoneDialog } from "@/components/board/board-time-zone-dialog";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Logo } from "@/components/ui/logo";
import { renameBoard } from "@/lib/auth-actions";
import type { BoardTimeZonePreview } from "@/lib/types";

interface BoardToolbarProps {
  slug: string;
  name: string;
  timeZone: string;
  canRename: boolean;
  onPreviewTimeZone: (timeZone: string) => Promise<BoardTimeZonePreview>;
  onSaveTimeZone: (expectedTimeZone: string, timeZone: string) => Promise<void>;
  viewerCount: number;
  isConnected: boolean;
  onDeleteBoard: () => void;
  onExport: () => void;
  onImport: () => void;
}

export function BoardToolbar({
  slug,
  name,
  timeZone,
  canRename,
  onPreviewTimeZone,
  onSaveTimeZone,
  viewerCount,
  isConnected,
  onDeleteBoard,
  onExport,
  onImport,
}: BoardToolbarProps) {
  const [title, setTitle] = useState(name);
  const [editValue, setEditValue] = useState(name);
  const [isEditing, setIsEditing] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [isTimeZoneDialogOpen, setIsTimeZoneDialogOpen] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const isSavingRef = useRef(false);

  useEffect(() => {
    setTitle(name);
    setEditValue(name);
  }, [name]);

  useEffect(() => {
    if (isEditing) {
      inputRef.current?.focus();
      inputRef.current?.select();
    }
  }, [isEditing]);

  async function saveName() {
    if (isSavingRef.current) return;
    const nextName = editValue.trim();
    if (!nextName) {
      setError("Escribe un nombre para el tablero.");
      return;
    }
    if (nextName === title) {
      setIsEditing(false);
      setError(null);
      return;
    }

    setIsSaving(true);
    isSavingRef.current = true;
    setError(null);
    let result: Awaited<ReturnType<typeof renameBoard>>;
    try {
      result = await renameBoard(slug, nextName);
    } catch {
      result = { error: "No se pudo confirmar el cambio. Inténtalo de nuevo." };
    }
    setIsSaving(false);
    isSavingRef.current = false;
    if (result.error || !result.name) {
      setError(result.error ?? "No se pudo cambiar el nombre.");
      return;
    }
    setTitle(result.name);
    setEditValue(result.name);
    setIsEditing(false);
  }

  return (
    <header className="flex shrink-0 items-center justify-between border-border border-b bg-surface-base px-4 py-3 md:px-6">
      <div className="flex min-w-0 items-center gap-3">
        <Logo size={24} showText={false} />
        <div className="mx-1 hidden h-4 w-px bg-border sm:block" />
        <Link
          href="/"
          className="shrink-0 rounded-md px-2 py-1 text-sm text-text-secondary hover:bg-surface-overlay hover:text-text-primary"
        >
          Tableros
        </Link>
        <div className="min-w-0">
          {isEditing ? (
            <input
              ref={inputRef}
              value={editValue}
              onChange={(event) => {
                setEditValue(event.target.value);
                if (error) setError(null);
              }}
              onBlur={() => void saveName()}
              onKeyDown={(event) => {
                if (event.key === "Enter") {
                  event.preventDefault();
                  void saveName();
                }
                if (event.key === "Escape") {
                  setEditValue(title);
                  setError(null);
                  setIsEditing(false);
                }
              }}
              maxLength={100}
              aria-label="Nombre del tablero"
              aria-invalid={Boolean(error)}
              aria-describedby={error ? "board-rename-error" : undefined}
              disabled={isSaving}
              className="w-full min-w-24 rounded-md border border-accent bg-surface-raised px-2 py-1 font-semibold text-base text-text-primary outline-none"
            />
          ) : (
            <div className="flex items-center gap-1">
              <h1
                className="truncate font-semibold text-base text-text-primary"
                title={title}
              >
                {title}
              </h1>
              {canRename ? (
                <button
                  type="button"
                  onClick={() => {
                    setEditValue(title);
                    setError(null);
                    setIsEditing(true);
                  }}
                  aria-label="Cambiar el nombre del tablero"
                  title="Cambiar el nombre del tablero"
                  className="rounded-md p-1 text-text-muted hover:bg-surface-overlay hover:text-text-primary"
                >
                  <IconPencil size={15} />
                </button>
              ) : null}
            </div>
          )}
          {error ? (
            <p
              id="board-rename-error"
              className="text-red-300 text-xs"
              role="alert"
            >
              {error}
            </p>
          ) : null}
        </div>

        {/* Live viewer count & connection status */}
        {(viewerCount > 1 || !isConnected) && (
          <div className="flex items-center gap-1.5 rounded-full bg-surface-overlay px-2.5 py-1">
            <span
              className={`h-1.5 w-1.5 rounded-full ${
                isConnected ? "bg-green-500" : "bg-red-500"
              }`}
              style={
                isConnected
                  ? { animation: "pulse-dot 2s ease-in-out infinite" }
                  : undefined
              }
            />
            <IconUsers size={12} className="text-text-muted" />
            <span className="font-medium text-[11px] text-text-secondary">
              {viewerCount}
            </span>
          </div>
        )}
      </div>

      <div className="flex items-center gap-1">
        {canRename ? (
          <>
            <DropdownMenu>
              <DropdownMenuTrigger
                title="Más acciones del tablero"
                aria-label="Más acciones del tablero"
                className="inline-flex h-8 w-8 items-center justify-center rounded-md bg-transparent text-text-secondary transition-colors hover:bg-surface-overlay hover:text-text-primary focus-visible:ring-1 focus-visible:ring-accent"
              >
                <IconDots size={18} aria-hidden="true" />
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end" className="min-w-56">
                <DropdownMenuItem
                  onClick={() => setIsTimeZoneDialogOpen(true)}
                  className="cursor-pointer"
                >
                  <IconWorld size={16} aria-hidden="true" />
                  Zona horaria del tablero
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
            <BoardTimeZoneDialog
              open={isTimeZoneDialogOpen}
              onClose={() => setIsTimeZoneDialogOpen(false)}
              timeZone={timeZone}
              onPreview={onPreviewTimeZone}
              onSave={onSaveTimeZone}
            />
          </>
        ) : null}
        {canRename ? (
          <Button
            variant="ghost"
            size="sm"
            onClick={onImport}
            title="Importar tablero"
          >
            <IconUpload size={16} />
            <span className="hidden sm:inline">Importar</span>
          </Button>
        ) : null}
        <Button
          variant="ghost"
          size="sm"
          onClick={onExport}
          title="Exportar tablero"
        >
          <IconDownload size={16} />
          <span className="hidden sm:inline">Exportar</span>
        </Button>
        {canRename ? (
          <Button
            variant="danger"
            size="sm"
            onClick={onDeleteBoard}
            title="Eliminar tablero"
          >
            <IconTrash size={16} />
            <span className="hidden sm:inline">Eliminar</span>
          </Button>
        ) : null}
        <BoardSignOutButton />
      </div>
    </header>
  );
}
