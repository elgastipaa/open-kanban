"use client";

import { IconRefresh } from "@tabler/icons-react";
import { useRouter } from "next/navigation";
import { Fragment, useState } from "react";
import {
  type AccessSuspensionPreview,
  accessSuspensionResultEffect,
  prepareAccessSuspensionResolutions,
} from "@/lib/access-suspension-flow";
import {
  AccessSuspensionError,
  previewAccountSuspension,
  suspendAccessWithSuccessions,
} from "@/lib/db/access";
import { createClient } from "@/lib/supabase/client";

interface AccessEntry {
  email: string;
  state: "pending" | "active" | "suspended";
  is_admin: boolean;
  linked: boolean;
}

type AccessAction = "admin_enable_access" | "admin_remove_pending_access";

interface AccessRpcError {
  code?: string;
  message?: string;
}

function getAccessErrorMessage(error: AccessRpcError): string {
  if (error.code === "55000") {
    return "No se puede suspender esta cuenta mientras tenga tableros a su nombre. Resolvé la propiedad antes de continuar.";
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
  if (error.code === "40001") {
    return "La cuenta o sus tableros cambiaron durante la operación. Revisá el estado e intentá nuevamente.";
  }
  return "No se pudo actualizar el acceso. Revisá el estado e intentá nuevamente.";
}

function suspensionErrorMessage(error: unknown): string {
  if (error instanceof AccessSuspensionError) {
    if (error.reason === "access_denied") {
      return "Tu facultad de administración cambió. Actualizá la lista antes de continuar.";
    }
    if (error.reason === "last_admin") {
      return "No se puede suspender al único administrador activo.";
    }
    if (error.reason === "conflict") {
      return "La cuenta, un sucesor o un tablero cambió desde la vista previa. Actualizá las opciones e intentá nuevamente.";
    }
  }
  return "No se pudo confirmar la suspensión. Revisá el estado e intentá nuevamente.";
}

function formatDeadline(value: string): string {
  return new Intl.DateTimeFormat("es-AR", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}

function relationshipLabel(value: "owner" | "recovery_owner" | "collaborator") {
  return value === "owner"
    ? "dueña de este tablero"
    : value === "recovery_owner"
      ? "responsable de recuperación"
      : "colaboradora";
}

export function AccessManager({ entries }: { entries: AccessEntry[] }) {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [busyEmail, setBusyEmail] = useState<string | null>(null);
  const [message, setMessage] = useState("");
  const [messageKind, setMessageKind] = useState<"error" | "success">(
    "success",
  );
  const [previewEmail, setPreviewEmail] = useState<string | null>(null);
  const [preview, setPreview] = useState<AccessSuspensionPreview | null>(null);
  const [selectedSuccessorByBoard, setSelectedSuccessorByBoard] = useState<
    Record<string, string>
  >({});
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

  async function previewSuspension(address: string) {
    const normalizedAddress = address.trim();
    setBusyEmail(normalizedAddress);
    setMessage("");
    try {
      const result = await previewAccountSuspension(
        createClient(),
        normalizedAddress,
      );
      if (result.status === "unavailable") {
        setPreviewEmail(null);
        setPreview(null);
        setMessageKind("error");
        setMessage("La cuenta ya no está activa. Actualizá la lista.");
        router.refresh();
        return;
      }
      setPreviewEmail(normalizedAddress);
      setPreview(result);
      setSelectedSuccessorByBoard({});
      setMessageKind("success");
      setMessage("");
    } catch (error) {
      setMessageKind("error");
      setMessage(suspensionErrorMessage(error));
    } finally {
      setBusyEmail(null);
    }
  }

  async function submitSuspension(address: string) {
    if (!preview || previewEmail?.toLowerCase() !== address.toLowerCase()) {
      setMessageKind("error");
      setMessage("Volvé a revisar la cuenta antes de confirmar la suspensión.");
      return;
    }
    const decision = prepareAccessSuspensionResolutions(
      preview.boards,
      selectedSuccessorByBoard,
    );
    if (decision.kind === "successor_required") {
      const names = preview.boards
        .filter((board) => decision.board_ids.includes(board.board_id))
        .map((board) => `«${board.name}»`)
        .join(", ");
      setMessageKind("error");
      setMessage(`Elegí un sucesor habilitado para ${names}.`);
      return;
    }
    if (decision.kind === "successor_invalid") {
      setMessageKind("error");
      setMessage("Actualizá la lista: una de las opciones ya no es elegible.");
      return;
    }

    const normalizedAddress = address.trim();
    setBusyEmail(normalizedAddress);
    setMessage("");
    try {
      const result = await suspendAccessWithSuccessions(
        createClient(),
        normalizedAddress,
        decision.resolutions,
      );
      const effect = accessSuspensionResultEffect(result.status);
      if (effect.kind === "stale_account") {
        setMessageKind("error");
        setMessage("La cuenta ya no está activa. Actualizá la lista.");
      } else if (effect.kind === "stale_preview") {
        setMessageKind("error");
        setMessage(
          "Un tablero o sucesor cambió desde la vista previa. Volvé a revisar la cuenta antes de confirmar.",
        );
      } else {
        setMessageKind("success");
        setMessage(
          "Acceso suspendido. Se confirmaron las decisiones de sucesión y la revocación de accesos asociadas.",
        );
      }
      if (effect.clearPreview) clearSuspensionPreview();
      if (effect.refreshAccess) {
        router.refresh();
      }
    } catch (error) {
      setMessageKind("error");
      setMessage(suspensionErrorMessage(error));
      if (
        error instanceof AccessSuspensionError &&
        ["access_denied", "conflict", "last_admin"].includes(error.reason)
      ) {
        clearSuspensionPreview();
        router.refresh();
      }
    } finally {
      setBusyEmail(null);
    }
  }

  function cancelSuspensionPreview() {
    clearSuspensionPreview();
    setMessage("");
  }

  function clearSuspensionPreview() {
    setPreviewEmail(null);
    setPreview(null);
    setSelectedSuccessorByBoard({});
  }

  async function addAccess(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const address = email.trim();
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
            type="text"
            inputMode="email"
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
              const isPreviewOpen =
                previewEmail?.toLowerCase() === entry.email.toLowerCase() &&
                preview !== null;
              const suspensionDecision = isPreviewOpen
                ? prepareAccessSuspensionResolutions(
                    preview.boards,
                    selectedSuccessorByBoard,
                  )
                : null;
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
                <Fragment key={entry.email}>
                  <tr className="border-white/10 border-t">
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
                            isPreviewOpen
                              ? cancelSuspensionPreview()
                              : previewSuspension(entry.email)
                          }
                          aria-label={`${isPreviewOpen ? "Cancelar" : "Revisar suspensión de"} ${entry.email}`}
                          className="text-neutral-300 underline underline-offset-4 hover:text-white disabled:opacity-60"
                        >
                          {busyEmail?.toLowerCase() ===
                          entry.email.toLowerCase()
                            ? "Revisando…"
                            : isPreviewOpen
                              ? "Cancelar"
                              : "Revisar suspensión"}
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
                  {isPreviewOpen ? (
                    <tr>
                      <td
                        colSpan={3}
                        className="border-white/10 border-t px-4 py-5"
                      >
                        <div className="rounded-xl border border-white/10 bg-neutral-950 p-4">
                          <h2 className="font-semibold">
                            Sucesión para {entry.email}
                          </h2>
                          <p className="mt-1 text-neutral-400 text-sm">
                            Revisá cada tablero y elegí una identidad habilitada
                            cuando corresponda. La suspensión, la revocación de
                            accesos y las sucesiones se confirman juntas.
                          </p>
                          {preview.boards.length === 0 ? (
                            <p className="mt-4 text-neutral-300 text-sm">
                              No hay tableros activos ni recuperables que
                              requieran una sucesión.
                            </p>
                          ) : (
                            <ul className="mt-4 divide-y divide-white/10">
                              {preview.boards.map((board) => (
                                <li
                                  key={board.board_id}
                                  className="py-4 first:pt-0 last:pb-0"
                                >
                                  <p className="font-medium">{board.name}</p>
                                  <p className="mt-1 text-neutral-500 text-xs">
                                    /{board.slug} ·{" "}
                                    {board.state === "active"
                                      ? "Activo"
                                      : "Recuperable"}{" "}
                                    · {relationshipLabel(board.relationship)} ·{" "}
                                    {board.active_member_count} miembros
                                    vigentes
                                    {board.state === "recoverable" &&
                                    board.deleted_at &&
                                    board.expires_at
                                      ? ` · ${formatDeadline(board.deleted_at)} – ${formatDeadline(board.expires_at)}`
                                      : ""}
                                  </p>
                                  {board.relationship === "collaborator" ? (
                                    <p className="mt-2 text-neutral-300 text-sm">
                                      Se retirará su membresía. El titular y el
                                      plazo de recuperación se conservan.
                                    </p>
                                  ) : board.state === "active" ? (
                                    board.candidates.length > 0 ? (
                                      <label className="mt-3 block max-w-xl">
                                        <span className="mb-2 block text-neutral-300 text-sm">
                                          Sucesor habilitado para este tablero
                                        </span>
                                        <select
                                          value={
                                            selectedSuccessorByBoard[
                                              board.board_id
                                            ] ?? ""
                                          }
                                          disabled={busyEmail !== null}
                                          onChange={(event) =>
                                            setSelectedSuccessorByBoard(
                                              (current) => ({
                                                ...current,
                                                [board.board_id]:
                                                  event.target.value,
                                              }),
                                            )
                                          }
                                          className="min-h-11 w-full rounded-lg border border-white/15 bg-black px-3 text-white outline-none focus:border-white/40 disabled:opacity-60"
                                        >
                                          <option value="">
                                            Elegí una identidad
                                          </option>
                                          {board.candidates.map((candidate) => (
                                            <option
                                              key={candidate.user_id}
                                              value={candidate.user_id}
                                            >
                                              {candidate.email}
                                              {candidate.is_admin
                                                ? " · Administrador"
                                                : ""}
                                            </option>
                                          ))}
                                        </select>
                                      </label>
                                    ) : (
                                      <p className="mt-2 text-amber-100 text-sm">
                                        No hay colaboradoras habilitadas para
                                        recibirlo. Quedará recuperable durante
                                        siete días.
                                      </p>
                                    )
                                  ) : board.relationship === "owner" &&
                                    board.recovery_owner_is_active ? (
                                    <p className="mt-2 text-neutral-300 text-sm">
                                      Se conserva la autoridad habilitada actual
                                      de recuperación y el vencimiento original.
                                    </p>
                                  ) : board.candidates.length > 0 ? (
                                    <label className="mt-3 block max-w-xl">
                                      <span className="mb-2 block text-neutral-300 text-sm">
                                        Identidad habilitada para la
                                        recuperación
                                      </span>
                                      <select
                                        value={
                                          selectedSuccessorByBoard[
                                            board.board_id
                                          ] ?? ""
                                        }
                                        disabled={busyEmail !== null}
                                        onChange={(event) =>
                                          setSelectedSuccessorByBoard(
                                            (current) => ({
                                              ...current,
                                              [board.board_id]:
                                                event.target.value,
                                            }),
                                          )
                                        }
                                        className="min-h-11 w-full rounded-lg border border-white/15 bg-black px-3 text-white outline-none focus:border-white/40 disabled:opacity-60"
                                      >
                                        <option value="">
                                          Elegí una identidad
                                        </option>
                                        {board.candidates.map((candidate) => (
                                          <option
                                            key={candidate.user_id}
                                            value={candidate.user_id}
                                          >
                                            {candidate.email}
                                            {candidate.is_admin
                                              ? " · Administrador"
                                              : ""}
                                          </option>
                                        ))}
                                      </select>
                                    </label>
                                  ) : (
                                    <p className="mt-2 text-amber-100 text-sm">
                                      No hay otra identidad habilitada elegible.
                                      El tablero seguirá recuperable sin titular
                                      asignado hasta su vencimiento original.
                                    </p>
                                  )}
                                </li>
                              ))}
                            </ul>
                          )}
                          <div className="mt-5 flex flex-wrap gap-3">
                            <button
                              type="button"
                              disabled={
                                busyEmail !== null ||
                                suspensionDecision?.kind !== "ready"
                              }
                              onClick={() => submitSuspension(entry.email)}
                              className="rounded-lg bg-white px-4 py-2.5 font-semibold text-neutral-950 transition hover:bg-neutral-200 disabled:opacity-60"
                            >
                              {busyEmail?.toLowerCase() ===
                              entry.email.toLowerCase()
                                ? "Suspendiendo…"
                                : "Confirmar suspensión"}
                            </button>
                            <button
                              type="button"
                              disabled={busyEmail !== null}
                              onClick={cancelSuspensionPreview}
                              className="rounded-lg border border-white/15 px-4 py-2.5 text-neutral-200 hover:bg-white/5 disabled:opacity-60"
                            >
                              Cancelar
                            </button>
                          </div>
                        </div>
                      </td>
                    </tr>
                  ) : null}
                </Fragment>
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
        La gestión de acceso no concede lectura del contenido privado de los
        tableros.
      </p>
    </section>
  );
}
