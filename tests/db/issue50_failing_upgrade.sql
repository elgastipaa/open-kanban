\set ON_ERROR_STOP on
BEGIN;
ALTER TABLE public.boards ADD COLUMN issue50_failed_upgrade_marker text;
SELECT 1 / 0;
COMMIT;
