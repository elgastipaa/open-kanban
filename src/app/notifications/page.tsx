import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { TaskNotificationsInbox } from "@/components/notifications/task-notifications-inbox";
import { resolveApplicationAccess } from "@/lib/auth";
import { listMyTaskNotifications } from "@/lib/db/task-notifications";
import { createClient } from "@/lib/supabase/server";
import type { TaskNotificationPage } from "@/lib/task-notification-state";

export const metadata: Metadata = {
  title: "Novedades",
  description: "Novedades recientes de tus tareas asignadas.",
  robots: { index: false, follow: false, nocache: true },
};

export default async function NotificationsPage() {
  const supabase = await createClient();
  const { data: authData } = await supabase.auth.getUser();
  if (!authData.user) {
    redirect("/login?next=%2Fnotifications");
  }
  const access = await resolveApplicationAccess(supabase);
  if (access.status !== "active") redirect("/");

  let initialPage: TaskNotificationPage | null = null;
  let initialLoadFailed = false;
  try {
    initialPage = await listMyTaskNotifications(supabase, "all", 30);
  } catch {
    initialLoadFailed = true;
  }

  return (
    <main className="mx-auto min-h-dvh max-w-5xl bg-surface-base px-5 py-8 text-text-primary sm:px-8">
      <header className="flex flex-wrap items-center justify-between gap-4 border-border border-b pb-6">
        <div>
          <p className="text-sm text-text-secondary">OpenKanban</p>
          <h1 className="mt-1 font-bold font-display text-3xl tracking-tight">
            Novedades
          </h1>
        </div>
        <Link
          href="/"
          className="rounded-lg border border-border px-4 py-2 text-sm text-text-secondary transition hover:bg-surface-hover hover:text-text-primary focus-visible:outline-2 focus-visible:outline-focus-ring focus-visible:outline-offset-2"
        >
          Volver a tus tableros
        </Link>
      </header>
      <TaskNotificationsInbox
        initialPage={initialPage}
        initialLoadFailed={initialLoadFailed}
      />
    </main>
  );
}
