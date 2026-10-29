BEGIN;

-- A task write can begin before another transaction and update the row after
-- it. now() reflects transaction start; use a strictly increasing row version
-- so clients can recognize the response produced by the later update.
CREATE OR REPLACE FUNCTION public.update_task_updated_at_monotonic()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := GREATEST(
    clock_timestamp(),
    OLD.updated_at + INTERVAL '1 microsecond'
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tasks_updated_at ON public.tasks;
CREATE TRIGGER tasks_updated_at
  BEFORE UPDATE ON public.tasks
  FOR EACH ROW
  EXECUTE FUNCTION public.update_task_updated_at_monotonic();

COMMIT;
