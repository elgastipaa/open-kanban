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
  assert.match(prepareRoute, /createTaskAttachmentServiceClient/u);
  assert.match(prepareRoute, /createPortableBoardImportAdapter/u);
  assert.match(prepareRoute, /session\.actorId/u);
  assert.match(prepareRoute, /instanceof ZodError/u);
  assert.match(prepareRoute, /no cumple el formato permitido/u);
  assert.match(prepareRoute, /MAX_PORTABLE_BOARD_IMPORT_BYTES/u);
  assert.match(prepareRoute, /preparePortableBoardImport\(/u);
  assert.match(
    prepareRoute,
    /runAfterCurrentBoardOwnerCheck\([\s\S]*?\(\) => spoolPortableBoardImportRequest\(request\)/u,
  );
  assert.match(
    prepareRoute,
    /runAfterCurrentBoardOwnerCheck\([\s\S]*?\(\) => readBoundedRequestBody\(request\)/u,
  );
  assert.match(confirmRoute, /getTaskAttachmentSession\(\)/u);
  assert.match(confirmRoute, /confirm_board_import_p/u);
  assert.match(confirmRoute, /p_expected_content_revision/u);
  assert.match(confirmRoute, /p_source_sha256/u);
  assert.match(confirmRoute, /confirm_board_import_v2_p/u);
  assert.match(confirmRoute, /p_member_mappings/u);
  assert.match(confirmRoute, /member_conflict/u);
  assert.match(confirmRoute, /MAX_PORTABLE_BOARD_IMPORT_DECISION_BYTES/u);
  assert.match(confirmRoute, /readBoundedRequestBody/u);
  const labelsRoute = await source(
    "src/app/api/boards/[slug]/import/[operationId]/labels/route.ts",
  );
  assert.match(labelsRoute, /set_board_import_v2_label_resolutions_p/u);
  assert.match(labelsRoute, /readBoundedRequestBody/u);
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
  assert.doesNotMatch(dialog, /prepareError\.message|confirmError\.message/u);
  assert.match(dialog, /typeof row\?\.message === "string"/u);
  assert.match(dialog, /application\/zip/u);
  assert.match(dialog, /"storage"/u);
  assert.match(dialog, /role="alert"/u);
  assert.match(dialog, /<output aria-live="polite"/u);
  assert.match(dialog, /Persona importada/u);
  assert.match(dialog, /compareBoardImportHeaders/u);
  assert.match(dialog, /current_board/u);
  assert.match(dialog, /proposed_board/u);
  assert.match(dialog, /sin asignar/iu);
  assert.match(dialog, /assigneeMappings/u);
  assert.match(dialog, /labelConflicts/u);
  assert.match(dialog, /label_renames/u);
  assert.match(dialog, /preparación guardada/u);
  assert.match(
    dialog,
    /No tienes\s+que volver a seleccionar ni subir el archivo/u,
  );
  assert.match(board, /<BoardImportDialog/u);
  assert.doesNotMatch(board, /importBoard\(/u);
  assert.match(toolbar, /canRename \? \(/u);
  const recoveriesRoute = await source(
    "src/app/api/boards/[slug]/import/recoveries/route.ts",
  );
  const restoreConfirmRoute = await source(
    "src/app/api/boards/[slug]/import/recoveries/[operationId]/confirm/route.ts",
  );
  assert.match(recoveriesRoute, /list_board_import_recoveries_p/u);
  assert.match(recoveriesRoute, /prepare_board_import_restore_p/u);
  assert.match(restoreConfirmRoute, /confirm_board_import_restore_p/u);
  assert.match(restoreConfirmRoute, /p_expected_content_revision/u);
  assert.match(dialog, /Recuperar contenido previo a una importación/u);
  assert.match(dialog, /recuperable hasta/u);
  assert.match(dialog, /Confirmar recuperación/u);
  assert.match(dialog, /prepara una vista nueva/u);
});

test("restore snapshots headers and publishes only an unexpired owner preview", async () => {
  const migration = await source(
    "supabase/migrations/071_restore_import_replacements.sql",
  );
  const dialog = await source("src/components/board/board-import-dialog.tsx");
  const cleanupRoute = await source(
    "src/app/api/cron/task-attachment-cleanup/route.ts",
  );

  assert.match(migration, /retained_board_name text/u);
  assert.match(migration, /retained_time_zone text/u);
  assert.match(
    migration,
    /BEFORE INSERT ON public\.board_generation_retention/u,
  );
  assert.match(
    migration,
    /'reason', CASE WHEN retention\.retained_board_name IS NULL/u,
  );
  assert.match(
    migration,
    /CREATE FUNCTION public\.list_board_import_recoveries_p/u,
  );
  assert.match(
    migration,
    /CREATE FUNCTION public\.prepare_board_import_restore_p/u,
  );
  assert.match(
    migration,
    /CREATE FUNCTION public\.confirm_board_import_restore_p/u,
  );
  assert.match(
    migration,
    /operation\.expected_content_revision IS DISTINCT FROM v_revision/u,
  );
  assert.match(migration, /retention\.expires_at <= v_now/u);
  assert.match(
    migration,
    /attachment\.state NOT IN \('active', 'recoverable'\)/u,
  );
  assert.match(migration, /'content_revision', v_revision \+ 1/u);
  assert.match(migration, /replacement_generation_id/u);
  assert.match(migration, /retained_at, expires_at/u);
  assert.match(migration, /interval '168 hours'/u);
  assert.match(migration, /cleanup_expired_board_import_restore_operations_p/u);
  assert.match(
    cleanupRoute,
    /cleanup_expired_board_import_restore_operations_p/u,
  );
  assert.match(dialog, /propietario actual/u);
  assert.match(dialog, /membresías, los avisos y las preferencias actuales/u);
});

test("v2 preview returns and compares destination and proposed board headers", async () => {
  const migration = await source(
    "supabase/migrations/070_complete_v2_board_import.sql",
  );
  const dialog = await source("src/components/board/board-import-dialog.tsx");

  assert.match(migration, /'current_board'[\s\S]*?'proposed_board'/u);
  assert.match(migration, /'name', board\.name/u);
  assert.match(migration, /'time_zone', board\.time_zone/u);
  assert.match(dialog, /Nombre y zona horaria propuestos/u);
  assert.match(dialog, /actual «\s*\{change\.current\}\s*»;\s*respaldo/u);
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
  const retentionCleanupStart = migration.indexOf(
    "CREATE FUNCTION public.cleanup_expired_board_generation_retention_p",
  );
  assert.notEqual(retentionCleanupStart, -1);
  const retentionCleanup = migration.slice(retentionCleanupStart);
  assert.match(retentionCleanup, /v_limit := LEAST\(p_limit, 100\)/u);
  assert.match(retentionCleanup, /EXIT WHEN v_cleaned >= v_limit/u);
  assert.match(
    retentionCleanup,
    /LIMIT v_limit - v_cleaned\s+FOR UPDATE OF retention SKIP LOCKED/u,
  );
  assert.match(migration, /generation_id = v_generation_id/u);
  assert.doesNotMatch(migration, /board_import_restore_previews/u);
  assert.doesNotMatch(migration, /list_board_import_recoveries_p/u);
  assert.doesNotMatch(migration, /prepare_board_import_restore_p/u);
  assert.doesNotMatch(migration, /confirm_board_import_restore_p/u);
  assert.match(cleanupRoute, /cleanup_expired_board_import_operations_p/u);
  assert.match(cleanupRoute, /cleanup_expired_board_generation_retention_p/u);
});

test("v2 requires explicit assignment decisions and explicit collision-free label names", async () => {
  const migration = await source(
    "supabase/migrations/070_complete_v2_board_import.sql",
  );
  assert.match(
    migration,
    /CREATE TABLE public\.board_import_v2_member_mappings/u,
  );
  assert.match(migration, /CREATE FUNCTION public\.confirm_board_import_v2_p/u);
  assert.match(
    migration,
    /CREATE TABLE public\.board_import_v2_label_resolutions/u,
  );
  assert.match(
    migration,
    /CREATE FUNCTION public\.set_board_import_v2_label_resolutions_p/u,
  );
  assert.match(migration, /board_label_name_ci_ai/u);
  assert.match(migration, /member_conflict/u);
  assert.match(migration, /label_conflict/u);
  assert.match(migration, /assignee_id = mapping\.target_user_id/u);
  assert.match(migration, /resolution\.name/u);
});
