import Link from "next/link";
import { SignInButton } from "@/components/auth/sign-in-button";
import { Logo } from "@/components/ui/logo";
import { getSafeNextPath } from "@/lib/auth";

interface LoginPageProps {
  searchParams: Promise<{ next?: string; error?: string }>;
}

export default async function LoginPage({ searchParams }: LoginPageProps) {
  const params = await searchParams;
  const nextPath = getSafeNextPath(params.next);

  return (
    <main className="flex min-h-dvh items-center justify-center bg-black px-5 py-12 text-white">
      <section className="w-full max-w-md rounded-3xl border border-white/10 bg-neutral-950 p-8 shadow-2xl sm:p-10">
        <Link href="/" aria-label="OpenKanban, inicio">
          <Logo />
        </Link>
        <h1 className="mt-10 font-bold font-display text-3xl tracking-tight">
          Accede a tus tableros
        </h1>
        <p className="mt-3 text-neutral-400 text-sm leading-6">
          OpenKanban es una aplicación cerrada. Inicia sesión con Google; una
          persona administradora debe habilitar tu acceso.
        </p>
        {params.error ? (
          <p
            className="mt-5 rounded-xl border border-red-400/20 bg-red-400/5 p-3 text-red-200 text-sm"
            role="alert"
          >
            No se pudo completar el inicio de sesión. Puedes intentarlo otra
            vez.
          </p>
        ) : null}
        <div className="mt-8">
          <SignInButton nextPath={nextPath} />
        </div>
        <p className="mt-6 text-center text-neutral-500 text-xs">
          No se crean cuentas públicas. El acceso depende de la habilitación de
          la aplicación.
        </p>
      </section>
    </main>
  );
}
