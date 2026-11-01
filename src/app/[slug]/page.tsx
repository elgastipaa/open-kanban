import type { Metadata } from "next";
import { notFound, redirect } from "next/navigation";
import { Board } from "@/components/board/board";
import { Unavailable } from "@/components/board/Unavailable";
import { resolveApplicationAccess } from "@/lib/auth";
import { getFullBoard } from "@/lib/db";
import { listAssignableBoardMembers } from "@/lib/db/my-tasks";
import { myTasksHref } from "@/lib/my-tasks-navigation";
import { createClient } from "@/lib/supabase/server";
import type { AssignableBoardMember, MyTasksOrder } from "@/lib/types";

interface BoardPageProps {
  params: Promise<{ slug: string }>;
  searchParams: Promise<{
    task?: string | string[];
    from?: string | string[];
    order?: string | string[];
  }>;
}

export async function generateMetadata({
  params,
}: BoardPageProps): Promise<Metadata> {
  await params;
  return {
    title: "Tablero privado",
    description: "Tablero privado de OpenKanban.",
    robots: {
      index: false,
      follow: false,
      nocache: true,
    },
  };
}

export default async function BoardPage({
  params,
  searchParams,
}: BoardPageProps) {
  const { slug } = await params;
  const query = await searchParams;
  const requestedTaskId =
    typeof query.task === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      query.task,
    )
      ? query.task
      : null;
  const fromMyTasks = query.from === "my-tasks";
  const myTasksReturnOrder: MyTasksOrder =
    query.order === "created" ? "created" : "due";
  const returnQuery = new URLSearchParams();
  if (requestedTaskId) returnQuery.set("task", requestedTaskId);
  if (fromMyTasks) {
    returnQuery.set("from", "my-tasks");
    returnQuery.set("order", myTasksReturnOrder);
  }
  const boardReturnPath = `/${slug}${returnQuery.size ? `?${returnQuery}` : ""}`;
  const supabase = await createClient();
  const { data: authData } = await supabase.auth.getUser();
  if (!authData.user) {
    redirect(`/login?next=${encodeURIComponent(boardReturnPath)}`);
  }

  const access = await resolveApplicationAccess(supabase);
  if (access.status !== "active") redirect("/");

  let boardData = null;

  try {
    boardData = await getFullBoard(supabase, slug);
  } catch {
    return <Unavailable />;
  }

  if (!boardData) notFound();

  const initialTaskId = fromMyTasks ? requestedTaskId : null;
  if (
    fromMyTasks &&
    initialTaskId &&
    !boardData.columns.some((column) =>
      column.tasks.some((task) => task.id === initialTaskId),
    )
  ) {
    redirect(myTasksHref(myTasksReturnOrder));
  }

  let assignableMembers: AssignableBoardMember[] | null = null;
  try {
    assignableMembers = await listAssignableBoardMembers(supabase, slug);
  } catch {
    assignableMembers = null;
  }

  return (
    <Board
      slug={slug}
      initialBoard={boardData.board}
      initialColumns={boardData.columns}
      ownerAuthUserId={authData.user.id}
      assignableMembers={assignableMembers}
      initialTaskId={initialTaskId}
      myTasksReturnHref={fromMyTasks ? myTasksHref(myTasksReturnOrder) : null}
    />
  );
}
