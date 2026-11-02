import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { MyTasksList } from "@/components/my-tasks/my-tasks-list";
import { resolveApplicationAccess } from "@/lib/auth";
import { getMyTasks } from "@/lib/db/my-tasks";
import { getMyViewPreferences } from "@/lib/db/view-preferences";
import { createClient } from "@/lib/supabase/server";
import type { MyTasksOrder } from "@/lib/types";
import type { ViewPreferenceSnapshot } from "@/lib/view-preference-state";

export const metadata: Metadata = {
  title: "Mis tareas",
  description: "Tareas que tienes asignadas en tus tableros.",
  robots: { index: false, follow: false, nocache: true },
};

interface MyTasksPageProps {
  searchParams: Promise<{ order?: string | string[] }>;
}

export default async function MyTasksPage({ searchParams }: MyTasksPageProps) {
  const { order: requestedOrder } = await searchParams;
  const firstRequestedOrder = Array.isArray(requestedOrder)
    ? requestedOrder[0]
    : requestedOrder;
  const explicitOrder: MyTasksOrder | null =
    firstRequestedOrder === "created" || firstRequestedOrder === "due"
      ? firstRequestedOrder
      : null;
  const supabase = await createClient();
  const { data: authData } = await supabase.auth.getUser();
  if (!authData.user) {
    redirect(`/login?next=${encodeURIComponent("/my-tasks")}`);
  }

  const access = await resolveApplicationAccess(supabase);
  if (access.status !== "active") redirect("/");

  let preferences: ViewPreferenceSnapshot | null = null;
  let preferencesLoadFailed = false;
  try {
    preferences = await getMyViewPreferences(supabase, {
      type: "my_tasks",
      boardId: null,
    });
  } catch {
    preferencesLoadFailed = true;
  }
  const savedOrder = preferences?.preferences?.order?.value;
  const order: MyTasksOrder =
    explicitOrder ?? (savedOrder === "created" ? "created" : "due");

  try {
    const entries = await getMyTasks(supabase, order);
    return (
      <MyTasksList
        actorId={authData.user.id}
        entries={entries}
        explicitOrder={explicitOrder}
        initialViewPreferences={preferences}
        initialViewPreferencesLoadFailed={preferencesLoadFailed}
        loadError={false}
      />
    );
  } catch {
    return (
      <MyTasksList
        actorId={authData.user.id}
        entries={[]}
        explicitOrder={explicitOrder}
        initialViewPreferences={preferences}
        initialViewPreferencesLoadFailed={preferencesLoadFailed}
        loadError
      />
    );
  }
}
