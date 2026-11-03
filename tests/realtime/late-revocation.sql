BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config(
  'request.jwt.claim.sub',
  '72000000-0000-4000-8000-000000000001',
  true
);

DO $$
DECLARE
  v_board public.boards%ROWTYPE;
  v_membership_id uuid;
  v_removal_status text;
BEGIN
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.owner_id = '72000000-0000-4000-8000-000000000001'
  ORDER BY board.created_at DESC
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The synthetic owner board fixture is missing';
  END IF;

  SELECT member.membership_id INTO v_membership_id
  FROM public.list_board_members_p(v_board.slug) AS member
  WHERE member.user_id = '72000000-0000-4000-8000-000000000002';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The synthetic collaborator fixture is missing';
  END IF;

  PERFORM public.create_column_p(
    v_board.slug,
    v_board.id,
    'Señal de sincronización anterior a la revocación',
    0
  );
  SELECT removal.result->>'status' INTO v_removal_status
  FROM public.remove_board_collaborator_p(
    '72000000-0000-4000-8000-000000000004',
    v_board.id,
    v_membership_id
  ) AS removal(result);
  IF v_removal_status IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The collaborator removal did not confirm: %', v_removal_status;
  END IF;
END;
$$;

COMMIT;
