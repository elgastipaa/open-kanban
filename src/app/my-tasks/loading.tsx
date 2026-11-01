export default function LoadingMyTasks() {
  return (
    <main className="mx-auto min-h-dvh max-w-5xl bg-black px-5 py-8 text-white sm:px-8">
      <output
        className="mt-12 block text-center text-neutral-400 text-sm"
        aria-live="polite"
      >
        Cargando tus tareas…
      </output>
    </main>
  );
}
