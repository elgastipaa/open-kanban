import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

const repo = new URL("../../", import.meta.url);

async function source(path) {
  return readFile(new URL(path, repo), "utf8");
}

test("portable export routes bind package IDs to the current actor and board access", async () => {
  const createRoute = await source("src/app/api/boards/[slug]/export/route.ts");
  const downloadRoute = await source(
    "src/app/api/boards/[slug]/export/[exportId]/route.ts",
  );

  assert.match(createRoute, /getTaskAttachmentSession\(\)/u);
  assert.match(createRoute, /p_actor_id:\s*session\.actorId/u);
  assert.match(createRoute, /create_board_export_snapshot_p/u);
  assert.match(downloadRoute, /getTaskAttachmentSession\(\)/u);
  assert.match(downloadRoute, /p_actor_id:\s*actorId/u);
  assert.match(downloadRoute, /p_board_slug:\s*slug/u);
  assert.match(downloadRoute, /read_board_export_snapshot_page_p/u);
  assert.match(
    downloadRoute,
    /object_key !== `attachments\/\$\{storageObjectId\}`/u,
  );
  assert.match(
    downloadRoute,
    /name: `objects\/\$\{attachmentRef\}\.\$\{extension\}`/u,
  );
  assert.match(downloadRoute, /entity: "repetition_labels"/u);
  assert.match(downloadRoute, /\.download\(objectKey\)/u);
  assert.doesNotMatch(downloadRoute, /\bfetch\s*\(/u);
  assert.doesNotMatch(downloadRoute, /\.blob\s*\(/u);
});

test("the server snapshot is allow-listed, pinned, paged, and expiring", async () => {
  const migration = await source(
    "supabase/migrations/068_board_export_snapshots.sql",
  );

  assert.match(migration, /WITH board_snapshot AS MATERIALIZED/u);
  assert.match(migration, /CREATE TABLE public\.board_export_snapshot_items/u);
  assert.match(
    migration,
    /CREATE FUNCTION public\.board_export_package_ref_p/u,
  );
  assert.match(migration, /board_export_package_steps_p/u);
  assert.match(migration, /FOR SHARE OF attachment/u);
  assert.match(migration, /daily_repetition_occurrences/u);
  assert.match(migration, /transferred_to_series_id/u);
  assert.match(migration, /'calendar_pattern', series\.calendar_pattern/u);
  assert.match(migration, /'advance_days', series\.advance_days/u);
  assert.match(migration, /board_label_repetition_assignments/u);
  assert.match(
    migration,
    /event\.occurred_at >= v_created_at - interval '180 days'/u,
  );
  assert.match(migration, /label\.deleted_at IS NULL/u);
  assert.match(migration, /attachment\.state = 'active'/u);
  assert.match(
    migration,
    /pin\.pin_expires_at > pg_catalog\.clock_timestamp\(\)/u,
  );
  assert.match(migration, /cleanup_expired_board_export_snapshots_p/u);
  assert.match(migration, /snapshot\.actor_id = p_actor_id/u);
  assert.match(migration, /membership\.revoked_at IS NULL/u);
  assert.doesNotMatch(
    migration,
    /GRANT EXECUTE ON FUNCTION public\.(?:create|read)_board_export_snapshot_p[^;]*TO authenticated/isu,
  );

  const cleanupRoute = await source(
    "src/app/api/cron/task-attachment-cleanup/route.ts",
  );
  assert.match(cleanupRoute, /cleanup_expired_board_export_snapshots_p/u);
});

test("the export dialog warns about portable copies and starts a streamed download", async () => {
  const dialog = await source("src/components/board/board-export-dialog.tsx");
  const zip = await source("src/lib/portable-export-zip.ts");

  assert.match(dialog, /podrá conservar su[\s\S]{0,30}contenido/u);
  assert.match(dialog, /method: "POST"/u);
  assert.match(dialog, /download\.click\(\)/u);
  assert.doesNotMatch(dialog, /response\.blob\s*\(/u);
  assert.match(zip, /format: "openkanban-board"/u);
  assert.match(zip, /version: 2/u);
  assert.match(zip, /sha256/u);
  assert.match(zip, /ZIP64_SENTINEL/u);
});
