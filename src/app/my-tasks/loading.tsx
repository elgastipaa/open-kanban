export default function LoadingMyTasks() {
  return (
    <main className="mx-auto min-h-dvh max-w-5xl bg-surface-base px-5 py-8 text-text-primary sm:px-8">
      <output
        className="mt-12 block text-center text-sm text-text-secondary"
        aria-live="polite"
      >
        Cargando tus tareas…
      </output>
    </main>
  );
}
