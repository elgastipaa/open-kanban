import type { Metadata } from "next";
import { notFound, redirect } from "next/navigation";
import { Board } from "@/components/board/board";
import { Unavailable } from "@/components/board/Unavailable";
import { resolveApplicationAccess } from "@/lib/auth";
import { getFullBoard } from "@/lib/db";
import { listCurrentBoardMembers } from "@/lib/db/board-members";
import { hasOtherCurrentBoardMembers } from "@/lib/db/membership-departure";
import { listAssignableBoardMembers } from "@/lib/db/my-tasks";
import { myTasksHref } from "@/lib/my-tasks-navigation";
import { resolveSeriesTaskEditorIntent } from "@/lib/repetition-series-navigation";
import { createClient } from "@/lib/supabase/server";
import type {
  AssignableBoardMember,
  CurrentBoardMember,
  MyTasksOrder,
} from "@/lib/types";

interface BoardPageProps {
  params: Promise<{ slug: string }>;
  searchParams: Promise<{
    task?: string | string[];
    comment?: string | string[];
    from?: string | string[];
    order?: string | string[];
    edit_repetition?: string | string[];
    series_board?: string | string[];
    series_state?: string | string[];
    series_before_created_at?: string | string[];
    series_before_id?: string | string[];
    series_selected_id?: string | string[];
    series_selected_occurrence?: string | string[];
    series_selected_comment?: string | string[];
    series_history_before_on?: string | string[];
    series_history_before_id?: string | string[];
  }>;
}

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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
    typeof query.task === "string" && uuidPattern.test(query.task)
      ? query.task
      : null;
  const requestedCommentId =
    typeof query.comment === "string" && uuidPattern.test(query.comment)
      ? query.comment
      : null;
  const editRepetitionQuery =
    typeof query.edit_repetition === "string" ? query.edit_repetition : null;
  const seriesBoardQuery =
    typeof query.series_board === "string" &&
    uuidPattern.test(query.series_board)
      ? query.series_board
      : null;
  const seriesStateQuery =
    typeof query.series_state === "string" ? query.series_state : null;
  const seriesBeforeCreatedAt =
    typeof query.series_before_created_at === "string"
      ? query.series_before_created_at
      : null;
  const seriesBeforeId =
    typeof query.series_before_id === "string" &&
    uuidPattern.test(query.series_before_id)
      ? query.series_before_id
      : null;
  const seriesSelectedId =
    typeof query.series_selected_id === "string" &&
    uuidPattern.test(query.series_selected_id)
      ? query.series_selected_id
      : null;
  const seriesSelectedOccurrence =
    typeof query.series_selected_occurrence === "string" &&
    uuidPattern.test(query.series_selected_occurrence)
      ? query.series_selected_occurrence
      : null;
  const seriesSelectedComment =
    typeof query.series_selected_comment === "string" &&
    uuidPattern.test(query.series_selected_comment)
      ? query.series_selected_comment
      : null;
  const seriesHistoryBeforeOn =
    typeof query.series_history_before_on === "string" &&
    /^\d{4}-\d{2}-\d{2}$/.test(query.series_history_before_on)
      ? query.series_history_before_on
      : null;
  const seriesHistoryBeforeId =
    typeof query.series_history_before_id === "string" &&
    uuidPattern.test(query.series_history_before_id)
      ? query.series_history_before_id
      : null;
  const fromMyTasks = query.from === "my-tasks";
  const myTasksReturnOrder: MyTasksOrder =
    query.order === "created" ? "created" : "due";
  const returnQuery = new URLSearchParams();
  if (requestedTaskId) returnQuery.set("task", requestedTaskId);
  if (requestedTaskId && requestedCommentId) {
    returnQuery.set("comment", requestedCommentId);
  }
  if (fromMyTasks) {
    returnQuery.set("from", "my-tasks");
    returnQuery.set("order", myTasksReturnOrder);
  }
  if (
    editRepetitionQuery === "1" &&
    query.from === "series" &&
    requestedTaskId
  ) {
    returnQuery.set("edit_repetition", "1");
    returnQuery.set("from", "series");
    if (seriesBoardQuery) returnQuery.set("series_board", seriesBoardQuery);
    if (
      seriesStateQuery === "active" ||
      seriesStateQuery === "stopped" ||
      seriesStateQuery === "finished"
    ) {
      returnQuery.set("series_state", seriesStateQuery);
    }
    if (seriesBeforeCreatedAt && seriesBeforeId) {
      returnQuery.set("series_before_created_at", seriesBeforeCreatedAt);
      returnQuery.set("series_before_id", seriesBeforeId);
    }
    if (seriesSelectedId) {
      returnQuery.set("series_selected_id", seriesSelectedId);
    }
    if (seriesSelectedOccurrence) {
      returnQuery.set("series_selected_occurrence", seriesSelectedOccurrence);
    }
    if (seriesSelectedComment) {
      returnQuery.set("series_selected_comment", seriesSelectedComment);
    }
    if (seriesHistoryBeforeOn && seriesHistoryBeforeId) {
      returnQuery.set("series_history_before_on", seriesHistoryBeforeOn);
      returnQuery.set("series_history_before_id", seriesHistoryBeforeId);
    }
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

  const requestedTaskIsInBoard = Boolean(
    requestedTaskId &&
      boardData.columns.some((column) =>
        column.tasks.some((task) => task.id === requestedTaskId),
      ),
  );
  const repetitionEditorIntent = resolveSeriesTaskEditorIntent({
    taskId: requestedTaskId,
    editRepetition: editRepetitionQuery,
    from: typeof query.from === "string" ? query.from : null,
    seriesBoardId: seriesBoardQuery,
    seriesState: seriesStateQuery,
    seriesBeforeCreatedAt,
    seriesBeforeId,
    selectedSeriesId: seriesSelectedId,
    selectedOccurrenceId: seriesSelectedOccurrence,
    selectedCommentId: seriesSelectedComment,
    historyBeforeOn: seriesHistoryBeforeOn,
    historyBeforeId: seriesHistoryBeforeId,
    authorizedBoardTaskIds: boardData.columns.flatMap((column) =>
      column.tasks.map((task) => task.id),
    ),
  });
  const initialTaskId =
    fromMyTasks || requestedCommentId !== null
      ? requestedTaskId
      : requestedTaskIsInBoard
        ? requestedTaskId
        : null;
  if (
    (fromMyTasks || requestedCommentId !== null) &&
    initialTaskId &&
    !boardData.columns.some((column) =>
      column.tasks.some((task) => task.id === initialTaskId),
    )
  ) {
    redirect(fromMyTasks ? myTasksHref(myTasksReturnOrder) : `/${slug}`);
  }

  let assignableMembers: AssignableBoardMember[] | null = null;
  let currentMembers: CurrentBoardMember[] | null = null;
  let hasOtherCurrentMembers: boolean | null = null;
  try {
    assignableMembers = await listAssignableBoardMembers(supabase, slug);
  } catch {
    assignableMembers = null;
  }
  try {
    currentMembers = await listCurrentBoardMembers(supabase, slug);
  } catch {
    currentMembers = null;
  }
  if (boardData.board.role === "owner") {
    try {
      hasOtherCurrentMembers = await hasOtherCurrentBoardMembers(
        supabase,
        boardData.board.id,
      );
    } catch {
      hasOtherCurrentMembers = null;
    }
  }

  return (
    <Board
      slug={slug}
      initialBoard={boardData.board}
      initialColumns={boardData.columns}
      ownerAuthUserId={authData.user.id}
      assignableMembers={assignableMembers}
      currentMembers={currentMembers}
      hasOtherCurrentMembers={hasOtherCurrentMembers}
      initialTaskId={initialTaskId}
      initialCommentId={initialTaskId ? requestedCommentId : null}
      myTasksReturnHref={fromMyTasks ? myTasksHref(myTasksReturnOrder) : null}
      initialRepetitionEditTaskId={repetitionEditorIntent?.taskId ?? null}
      seriesReturnHref={repetitionEditorIntent?.returnHref ?? null}
    />
  );
}
