\set ON_ERROR_STOP on
\echo 'Testing the exact 168-hour task-comment recovery boundary'

DO $$
DECLARE
  v_deleted_at constant timestamptz := '2026-10-01 12:00:00+00';
  v_expires_at constant timestamptz := v_deleted_at + interval '168 hours';
BEGIN
  IF NOT public.task_comment_restore_window_open_p(
    v_deleted_at,
    v_expires_at - interval '1 microsecond'
  ) THEN
    RAISE EXCEPTION 'A comment was not restorable one microsecond before its deadline';
  END IF;
  IF public.task_comment_restore_window_open_p(v_deleted_at, v_expires_at) THEN
    RAISE EXCEPTION 'A comment remained restorable at its exact deadline';
  END IF;
END;
$$;
