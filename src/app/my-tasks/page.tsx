import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { MyTasksList } from "@/components/my-tasks/my-tasks-list";
import { resolveApplicationAccess } from "@/lib/auth";
import { getMyTasks } from "@/lib/db/my-tasks";
import { createClient } from "@/lib/supabase/server";
import type { MyTasksOrder } from "@/lib/types";

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
  const order: MyTasksOrder = requestedOrder === "created" ? "created" : "due";
  const supabase = await createClient();
  const { data: authData } = await supabase.auth.getUser();
  if (!authData.user) {
    redirect(`/login?next=${encodeURIComponent(`/my-tasks?order=${order}`)}`);
  }

  const access = await resolveApplicationAccess(supabase);
  if (access.status !== "active") redirect("/");

  try {
    const entries = await getMyTasks(supabase, order);
    return <MyTasksList entries={entries} order={order} loadError={false} />;
  } catch {
    return <MyTasksList entries={[]} order={order} loadError />;
  }
}
