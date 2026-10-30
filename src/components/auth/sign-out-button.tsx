import { signOut } from "@/lib/auth-actions";

export function SignOutButton() {
  return (
    <form action={signOut}>
      <button
        type="submit"
        className="rounded-lg border border-white/15 px-4 py-2 text-neutral-300 text-sm transition hover:bg-white/5 hover:text-white"
      >
        Cerrar sesión
      </button>
    </form>
  );
}
