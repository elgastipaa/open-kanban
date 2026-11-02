import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

const repo = new URL("../../", import.meta.url);

async function source(path) {
  return readFile(new URL(path, repo), "utf8");
}

test("import and confirm routes authenticate the actor and call atomic owner RPCs", async () => {
  const prepareRoute = await source(
    "src/app/api/boards/[slug]/import/route.ts",
  );
  const confirmRoute = await source(
    "src/app/api/boards/[slug]/import/[operationId]/confirm/route.ts",
  );

  assert.match(prepareRoute, /getTaskAttachmentSession\(\)/u);
  assert.match(prepareRoute, /readBoundedRequestBody\(request\)/u);
  assert.match(prepareRoute, /readLegacyBoardImportFile\(file\)/u);
  assert.match(prepareRoute, /prepare_board_import_p/u);
  assert.match(prepareRoute, /session\.client\.rpc/u);
  assert.doesNotMatch(prepareRoute, /createTaskAttachmentServiceClient/u);
  assert.match(confirmRoute, /getTaskAttachmentSession\(\)/u);
  assert.match(confirmRoute, /confirm_board_import_p/u);
  assert.match(confirmRoute, /p_expected_content_revision/u);
  assert.match(confirmRoute, /p_source_sha256/u);
  assert.doesNotMatch(confirmRoute, /createTaskAttachmentServiceClient/u);
  assert.match(prepareRoute, /private, no-store/u);
  assert.match(confirmRoute, /private, no-store/u);
});

test("the owner-facing UI shows the version and requires explicit replacement confirmation", async () => {
  const dialog = await source("src/components/board/board-import-dialog.tsx");
  const board = await source("src/components/board/board.tsx");
  const toolbar = await source("src/components/board/board-toolbar.tsx");

  assert.match(dialog, /Confirmar reemplazo/u);
  assert.match(dialog, /no se combinarán/u);
  assert.match(dialog, /propietario y los integrantes/u);
  assert.match(dialog, /siete días/u);
  assert.match(dialog, /Revisión del contenido/u);
  assert.match(
    dialog,
    /pendingPreparation\?\.operationId \?\? crypto\.randomUUID\(\)/u,
  );
  assert.match(dialog, /No se pudo confirmar el resultado de la preparación/u);
  assert.match(dialog, /No se pudo confirmar el resultado del reemplazo/u);
  assert.doesNotMatch(
    dialog,
    /prepareError\.message|confirmError\.message|row\?\.message/u,
  );
  assert.match(dialog, /role="alert"/u);
  assert.match(dialog, /<output aria-live="polite"/u);
  assert.match(board, /<BoardImportDialog/u);
  assert.doesNotMatch(board, /importBoard\(/u);
  assert.match(toolbar, /canRename \? \(/u);
  await assert.rejects(
    source("src/app/api/boards/[slug]/import/recoveries/route.ts"),
    { code: "ENOENT" },
  );
  await assert.rejects(
    source(
      "src/app/api/boards/[slug]/import/recoveries/[operationId]/confirm/route.ts",
    ),
    { code: "ENOENT" },
  );
});

test("the database stages invisible generations and revalidates publication under the board lock", async () => {
  const migration = await source(
    "supabase/migrations/069_safe_v1_board_import.sql",
  );
  const cleanupRoute = await source(
    "src/app/api/cron/task-attachment-cleanup/route.ts",
  );

  assert.match(migration, /CREATE TABLE public\.board_content_revisions/u);
  assert.match(migration, /CREATE TABLE public\.board_import_stage_contexts/u);
  assert.match(
    migration,
    /context\.transaction_id = pg_catalog\.txid_current\(\)/u,
  );
  assert.match(migration, /generation\.status = 'preparing'/u);
  assert.match(
    migration,
    /v_revision <> v_operation\.expected_content_revision/u,
  );
  assert.match(migration, /board_import_generation_hash_p/u);
  assert.match(migration, /retained_at \+ interval '168 hours'/u);
  assert.match(
    migration,
    /SET active_generation_id = v_operation\.generation_id/u,
  );
  assert.match(migration, /cleanup_expired_board_import_operations_p/u);
  assert.match(migration, /cleanup_expired_board_generation_retention_p/u);
  assert.match(migration, /confirmed_at <= v_now - interval '168 hours'/u);
  assert.match(
    migration,
    /LIMIT LEAST\(p_limit - v_cleaned, 100\)\s+FOR UPDATE OF operation SKIP LOCKED/u,
  );
  assert.match(
    migration,
    /LIMIT LEAST\(GREATEST\(p_limit - v_cleaned, 0\), 100\)/u,
  );
  assert.match(migration, /generation_id = v_generation_id/u);
  assert.doesNotMatch(migration, /board_import_restore_previews/u);
  assert.doesNotMatch(migration, /list_board_import_recoveries_p/u);
  assert.doesNotMatch(migration, /prepare_board_import_restore_p/u);
  assert.doesNotMatch(migration, /confirm_board_import_restore_p/u);
  assert.match(cleanupRoute, /cleanup_expired_board_import_operations_p/u);
  assert.match(cleanupRoute, /cleanup_expired_board_generation_retention_p/u);
});
