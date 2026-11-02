-- Serialize application-access administration and defer suspension until
-- the account's board ownership can be resolved by issue #19.
BEGIN;

CREATE OR REPLACE FUNCTION public.admin_enable_access(p_email text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_email text := lower(btrim(p_email));
BEGIN
  PERFORM public.require_application_admin();
  LOCK TABLE public.application_access IN SHARE ROW EXCLUSIVE MODE;
  PERFORM public.require_application_admin();

  IF v_email IS NULL OR length(v_email) > 254
    OR v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' THEN
    RAISE EXCEPTION 'Enter a valid Google email address' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.application_access(email, state)
  VALUES (v_email, 'pending')
  ON CONFLICT (email) DO UPDATE SET
    state = CASE
      WHEN public.application_access.state = 'suspended'
        AND public.application_access.auth_user_id IS NOT NULL THEN 'active'
      WHEN public.application_access.state = 'suspended' THEN 'pending'
      ELSE public.application_access.state
    END,
    updated_at = now();
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_remove_pending_access(p_email text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_removed boolean;
BEGIN
  PERFORM public.require_application_admin();
  LOCK TABLE public.application_access IN SHARE ROW EXCLUSIVE MODE;
  PERFORM public.require_application_admin();

  DELETE FROM public.application_access AS access
  WHERE access.email = lower(btrim(p_email))
    AND access.state = 'pending'
    AND access.auth_user_id IS NULL;
  v_removed := FOUND;
  RETURN v_removed;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_suspend_access(p_email text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_access public.application_access%ROWTYPE;
BEGIN
  PERFORM public.require_application_admin();
  LOCK TABLE public.application_access IN SHARE ROW EXCLUSIVE MODE;
  -- Recheck the actor after waiting for another administrator's operation.
  PERFORM public.require_application_admin();

  SELECT * INTO v_access
  FROM public.application_access AS access
  WHERE access.email = lower(btrim(p_email))
    AND access.auth_user_id IS NOT NULL
    AND access.state = 'active'
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_access.is_admin AND (
    SELECT count(*) FROM public.application_access AS active_admin
    WHERE active_admin.is_admin AND active_admin.state = 'active'
  ) <= 1 THEN
    RAISE EXCEPTION 'At least one active administrator must remain' USING ERRCODE = '23514';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.boards AS board
    WHERE board.owner_id = v_access.auth_user_id
  ) THEN
    RAISE EXCEPTION 'Account owns a board; ownership must be resolved before suspension'
      USING ERRCODE = '55000';
  END IF;

  UPDATE public.application_access AS access
  SET state = 'suspended', updated_at = now()
  WHERE access.email = v_access.email;
  RETURN true;
END;
$$;

COMMIT;
