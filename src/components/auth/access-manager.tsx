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

type AccessAction =
  | "admin_enable_access"
  | "admin_remove_pending_access"
  | "admin_suspend_access";

interface AccessRpcError {
  code?: string;
  message?: string;
}

function getAccessErrorMessage(error: AccessRpcError): string {
  if (error.code === "55000") {
    return "No se puede suspender esta cuenta porque posee tableros. La gestión de propiedad corresponde al issue #19.";
  }
  if (
    error.code === "23514" &&
    error.message?.includes("At least one active administrator must remain")
  ) {
    return "No se puede suspender al único administrador activo.";
  }
  if (
    error.code === "23514" &&
    error.message?.includes("Enter a valid Google email address")
  ) {
    return "Ingresá una dirección de correo válida.";
  }
  if (error.code === "42501") {
    return "Tu facultad de administración cambió. Actualizá la lista e intentá nuevamente.";
  }
  return "No se pudo actualizar el acceso. Revisá el estado e intentá nuevamente.";
}

export function AccessManager({ entries }: { entries: AccessEntry[] }) {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [busyEmail, setBusyEmail] = useState<string | null>(null);
  const [message, setMessage] = useState("");
  const [messageKind, setMessageKind] = useState<"error" | "success">(
    "success",
  );
  const activeAdminCount = entries.filter(
    (entry) => entry.is_admin && entry.state === "active",
  ).length;

  async function mutateAccess(
    rpc: AccessAction,
    address: string,
  ): Promise<boolean> {
    const normalizedAddress = address.trim();
    if (!normalizedAddress) {
      setMessageKind("error");
      setMessage("Ingresá una dirección de correo válida.");
      return false;
    }

    setBusyEmail(normalizedAddress);
    setMessage("");
    let error: AccessRpcError | null = null;
    try {
      const result = await createClient().rpc(rpc, {
        p_email: normalizedAddress,
      });
      error = result.error;
    } catch {
      error = {};
    } finally {
      setBusyEmail(null);
    }

    if (error) {
      setMessageKind("error");
      setMessage(getAccessErrorMessage(error));
      return false;
    }

    const currentEntry = entries.find(
      (entry) => entry.email.toLowerCase() === normalizedAddress.toLowerCase(),
    );
    setMessageKind("success");
    setMessage(
      rpc === "admin_remove_pending_access"
        ? "Autorización pendiente retirada."
        : rpc === "admin_suspend_access"
          ? "Acceso suspendido. El estado se comprueba en cada solicitud nueva."
          : currentEntry?.state === "suspended"
            ? "Acceso rehabilitado. Se conserva la identidad vinculada y los accesos a tableros no se restauran automáticamente."
            : currentEntry?.state === "pending"
              ? "La autorización pendiente ya existía. La vinculación requiere un correo verificado por Google."
              : currentEntry?.state === "active"
                ? "El acceso ya estaba habilitado."
                : "Autorización pendiente creada. La vinculación requiere un correo verificado por Google.",
    );
    router.refresh();
    return true;
  }

  async function addAccess(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const address = email.trim();
    if (!address) return;
    if (await mutateAccess("admin_enable_access", address)) setEmail("");
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
            autoComplete="email"
            required
            value={email}
            onChange={(event) => setEmail(event.target.value)}
            className="min-h-11 w-full rounded-lg border border-white/15 bg-black px-3 text-white outline-none focus:border-white/40"
          />
          <span className="mt-2 block text-neutral-500 text-xs">
            La primera sesión vincula esta autorización solo con un correo
            verificado por Google.
          </span>
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
        <p
          className={`mt-3 text-sm ${messageKind === "error" ? "text-red-200" : "text-neutral-300"}`}
          role={messageKind === "error" ? "alert" : "status"}
          aria-live={messageKind === "error" ? "assertive" : "polite"}
        >
          {message}
        </p>
      ) : null}

      <div className="mt-6 overflow-x-auto rounded-2xl border border-white/10">
        <table className="w-full min-w-[34rem] border-collapse text-left text-sm">
          <thead className="bg-neutral-950 text-neutral-400">
            <tr>
              <th className="px-4 py-3 font-medium" scope="col">
                Correo autorizado
              </th>
              <th className="px-4 py-3 font-medium" scope="col">
                Estado
              </th>
              <th className="px-4 py-3 font-medium" scope="col">
                Acción
              </th>
            </tr>
          </thead>
          <tbody>
            {entries.map((entry) => {
              const stateLabel =
                entry.state === "pending"
                  ? "Pendiente de primera sesión"
                  : entry.state === "active"
                    ? "Activa"
                    : "Suspendida";
              const action =
                entry.state === "suspended"
                  ? "rehabilitate"
                  : entry.state === "pending"
                    ? "remove"
                    : entry.state === "active" &&
                        (!entry.is_admin || activeAdminCount > 1)
                      ? "suspend"
                      : null;

              return (
                <tr key={entry.email} className="border-white/10 border-t">
                  <td className="px-4 py-4">{entry.email}</td>
                  <td className="px-4 py-4 text-neutral-300">
                    {stateLabel}
                    {entry.is_admin ? " · Administrador" : ""}
                  </td>
                  <td className="px-4 py-4">
                    {action === "remove" ? (
                      <button
                        type="button"
                        disabled={busyEmail !== null}
                        onClick={() =>
                          mutateAccess(
                            "admin_remove_pending_access",
                            entry.email,
                          )
                        }
                        aria-label={`Retirar autorización de ${entry.email}`}
                        className="text-neutral-300 underline underline-offset-4 hover:text-white disabled:opacity-60"
                      >
                        Retirar
                      </button>
                    ) : action === "suspend" ? (
                      <button
                        type="button"
                        disabled={busyEmail !== null}
                        onClick={() =>
                          mutateAccess("admin_suspend_access", entry.email)
                        }
                        aria-label={`Suspender acceso de ${entry.email}`}
                        className="text-neutral-300 underline underline-offset-4 hover:text-white disabled:opacity-60"
                      >
                        Suspender
                      </button>
                    ) : action === "rehabilitate" ? (
                      <button
                        type="button"
                        disabled={busyEmail !== null}
                        onClick={() =>
                          mutateAccess("admin_enable_access", entry.email)
                        }
                        aria-label={`Rehabilitar acceso de ${entry.email}`}
                        className="text-neutral-300 underline underline-offset-4 hover:text-white disabled:opacity-60"
                      >
                        Rehabilitar
                      </button>
                    ) : entry.is_admin && entry.state === "active" ? (
                      <span className="text-neutral-500">
                        Único administrador protegido
                      </span>
                    ) : (
                      <span className="text-neutral-500">—</span>
                    )}
                  </td>
                </tr>
              );
            })}
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
        La gestión global no concede lectura de tableros. Si la persona posee
        tableros, la suspensión queda bloqueada hasta resolver la propiedad en
        #19.
      </p>
    </section>
  );
}
