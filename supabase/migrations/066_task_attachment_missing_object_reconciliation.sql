BEGIN;

-- Record only an explicit Storage object-not-found result. Recheck current
-- membership and task context, then hide the phantom from the user list while
-- retaining quota until the cleanup worker confirms Storage absence.
CREATE FUNCTION public.mark_task_attachment_missing_p(
  p_actor_id uuid,
  p_slug text,
  p_task_id uuid,
  p_attachment_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_context record;
  v_attachment public.task_attachments%ROWTYPE;
BEGIN
  IF p_actor_id IS NULL OR p_slug IS NULL OR p_task_id IS NULL
    OR p_attachment_id IS NULL
    OR NOT public.is_enabled_application_identity_p(p_actor_id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT context.* INTO v_context
  FROM public.task_attachment_context_for_actor_p(
    p_actor_id, p_slug, p_task_id
  ) AS context;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  -- Keep the established board/task/membership -> attachment lock order.
  SELECT attachment.* INTO v_attachment
  FROM public.task_attachments AS attachment
  WHERE attachment.id = p_attachment_id
    AND attachment.task_id = p_task_id
  FOR UPDATE;
  IF NOT FOUND OR v_attachment.board_id <> v_context.board_id THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  IF v_attachment.state = 'missing' THEN
    RETURN jsonb_build_object('status', 'missing');
  END IF;
  IF v_attachment.state <> 'active' THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  UPDATE public.task_attachments AS attachment
  SET state = 'missing'
  WHERE attachment.id = p_attachment_id;

  RETURN jsonb_build_object('status', 'missing');
END;
$$;
REVOKE ALL ON FUNCTION public.mark_task_attachment_missing_p(uuid, text, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_task_attachment_missing_p(uuid, text, uuid, uuid)
  TO service_role;

COMMIT;
