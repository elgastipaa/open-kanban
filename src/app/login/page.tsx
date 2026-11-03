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
    <main className="flex min-h-dvh items-center justify-center bg-surface-base px-5 py-12 text-text-primary">
      <section className="w-full max-w-md rounded-3xl border border-border bg-surface-raised p-8 shadow-2xl sm:p-10">
        <Logo />
        <h1 className="mt-10 font-bold font-display text-3xl tracking-tight">
          Accede a tus tableros
        </h1>
        <p className="mt-3 text-sm text-text-secondary leading-6">
          OpenKanban es una aplicación cerrada. Inicia sesión con Google; una
          persona administradora debe habilitar tu acceso.
        </p>
        {params.error ? (
          <p
            className="mt-5 rounded-xl border border-priority-urgent/30 bg-priority-urgent/10 p-3 text-priority-urgent text-sm"
            role="alert"
          >
            No se pudo completar el inicio de sesión. Puedes intentarlo otra
            vez.
          </p>
        ) : null}
        <div className="mt-8">
          <SignInButton nextPath={nextPath} />
        </div>
        <p className="mt-6 text-center text-text-muted text-xs">
          No se crean cuentas públicas. El acceso depende de la habilitación de
          la aplicación.
        </p>
      </section>
    </main>
  );
}
