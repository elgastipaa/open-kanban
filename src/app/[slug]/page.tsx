import type { Metadata } from "next";
import { notFound, redirect } from "next/navigation";
import { Board } from "@/components/board/board";
import { Unavailable } from "@/components/board/Unavailable";
import { resolveApplicationAccess } from "@/lib/auth";
import { getFullBoard } from "@/lib/db";
import { createClient } from "@/lib/supabase/server";

interface BoardPageProps {
  params: Promise<{ slug: string }>;
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

export default async function BoardPage({ params }: BoardPageProps) {
  const { slug } = await params;
  const supabase = await createClient();
  const { data: authData } = await supabase.auth.getUser();
  if (!authData.user) {
    redirect(`/login?next=${encodeURIComponent(`/${slug}`)}`);
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

  return (
    <Board
      slug={slug}
      initialBoard={boardData.board}
      initialColumns={boardData.columns}
      ownerAuthUserId={authData.user.id}
    />
  );
}
