"use client";

import { IconRefresh } from "@tabler/icons-react";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface AccessEntry {
  email: string;
  state: "pending" | "active" | "suspended";
  is_admin: boolean;
  linked: boolean;
}

export function AccessManager({ entries }: { entries: AccessEntry[] }) {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [busyEmail, setBusyEmail] = useState<string | null>(null);
  const [message, setMessage] = useState("");

  async function mutateAccess(
    rpc:
      | "admin_enable_access"
      | "admin_remove_pending_access"
      | "admin_suspend_access",
    address: string,
  ) {
    setBusyEmail(address);
    setMessage("");
    const { error } = await createClient().rpc(rpc, { p_email: address });
    setBusyEmail(null);
    if (error) {
      setMessage("No se pudo actualizar ese acceso.");
      return;
    }
    setMessage("Acceso actualizado.");
    router.refresh();
  }

  async function addAccess(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const address = email.trim();
    if (!address) return;
    await mutateAccess("admin_enable_access", address);
    setEmail("");
  }

  return (
    <section className="mt-8">
      <form
        onSubmit={addAccess}
        className="flex flex-col gap-3 rounded-2xl border border-white/10 bg-neutral-950 p-5 sm:flex-row"
      >
        <label className="flex-1">
          <span className="mb-2 block font-medium text-sm">
            Correo de Google
          </span>
          <input
            type="email"
            autoComplete="off"
            required
            value={email}
            onChange={(event) => setEmail(event.target.value)}
            className="min-h-11 w-full rounded-lg border border-white/15 bg-black px-3 text-white outline-none focus:border-white/40"
          />
        </label>
        <button
          type="submit"
          disabled={busyEmail !== null}
          className="self-end rounded-lg bg-white px-5 py-3 font-semibold text-neutral-950 transition hover:bg-neutral-200 disabled:opacity-60"
        >
          Habilitar acceso
        </button>
      </form>

      {message ? (
        <output className="mt-3 text-neutral-300 text-sm">{message}</output>
      ) : null}

      <div className="mt-6 overflow-x-auto rounded-2xl border border-white/10">
        <table className="w-full min-w-[34rem] border-collapse text-left text-sm">
          <thead className="bg-neutral-950 text-neutral-400">
            <tr>
              <th className="px-4 py-3 font-medium">Cuenta habilitada</th>
              <th className="px-4 py-3 font-medium">Estado</th>
              <th className="px-4 py-3 font-medium">Acción</th>
            </tr>
          </thead>
          <tbody>
            {entries.map((entry) => (
              <tr key={entry.email} className="border-white/10 border-t">
                <td className="px-4 py-4">{entry.email}</td>
                <td className="px-4 py-4 text-neutral-300">
                  {entry.is_admin
                    ? "Administración"
                    : entry.state === "pending"
                      ? "Pendiente de primera sesión"
                      : entry.state === "active"
                        ? "Habilitada"
                        : "Suspendida"}
                </td>
                <td className="px-4 py-4">
                  {!entry.is_admin && entry.state === "pending" ? (
                    <button
                      type="button"
                      disabled={busyEmail !== null}
                      onClick={() =>
                        mutateAccess("admin_remove_pending_access", entry.email)
                      }
                      className="text-neutral-300 underline underline-offset-4 hover:text-white disabled:opacity-60"
                    >
                      Retirar
                    </button>
                  ) : !entry.is_admin && entry.state === "active" ? (
                    <button
                      type="button"
                      disabled={busyEmail !== null}
                      onClick={() =>
                        mutateAccess("admin_suspend_access", entry.email)
                      }
                      className="text-neutral-300 underline underline-offset-4 hover:text-white disabled:opacity-60"
                    >
                      Suspender
                    </button>
                  ) : (
                    <span className="text-neutral-500">—</span>
                  )}
                </td>
              </tr>
            ))}
            {entries.length === 0 ? (
              <tr>
                <td
                  colSpan={3}
                  className="px-4 py-8 text-center text-neutral-500"
                >
                  Todavía no hay accesos.
                </td>
              </tr>
            ) : null}
          </tbody>
        </table>
      </div>
      <p className="mt-4 flex items-center gap-2 text-neutral-500 text-xs">
        <IconRefresh size={14} aria-hidden="true" />
        La suspensión se comprueba en cada solicitud a datos y canales privados.
      </p>
    </section>
  );
}
