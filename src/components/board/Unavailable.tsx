import { IconCloudOff } from "@tabler/icons-react";
import Link from "next/link";
import { Logo } from "@/components/ui/logo";

export function Unavailable() {
  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-surface-base p-4 text-text-primary selection:bg-accent selection:text-black">
      {/* Top Branding */}
      <div className="absolute top-8 left-8">
        <Logo />
      </div>

      <div className="relative w-full max-w-lg">
        <div className="relative flex flex-col items-center rounded-3xl border border-border bg-surface-raised/50 p-10 text-center backdrop-blur-xl md:p-14">
          <div className="mb-8 flex h-20 w-20 items-center justify-center rounded-3xl border border-border bg-surface-hover text-priority-urgent ring-1 ring-border backdrop-blur-sm">
            <IconCloudOff size={40} strokeWidth={1.5} />
          </div>

          <h2 className="mb-4 font-bold font-display text-3xl text-text-primary tracking-tight md:text-4xl">
            No se pudo cargar el tablero
          </h2>

          <p className="mb-10 max-w-sm font-sans text-lg text-text-secondary leading-relaxed">
            El servicio no respondió. Puedes volver a tus tableros e intentarlo
            de nuevo más tarde.
          </p>

          <div className="flex w-full flex-col gap-4 sm:flex-row sm:justify-center">
            <Link
              href="/"
              className="group relative flex h-14 items-center justify-center overflow-hidden rounded-2xl bg-accent px-8 font-bold text-black transition-all hover:scale-[1.02] active:scale-[0.98] sm:min-w-[160px]"
            >
              <div className="absolute inset-0 bg-white opacity-0 transition-opacity group-hover:opacity-20" />
              Volver al inicio
            </Link>
          </div>

          <div className="mt-12 flex items-center gap-3 font-medium text-[10px] text-text-muted uppercase tracking-[0.2em]">
            <span className="h-px w-8 bg-border-hover" />
            Servicio no disponible
            <span className="h-px w-8 bg-border-hover" />
          </div>
        </div>
      </div>
    </div>
  );
}
