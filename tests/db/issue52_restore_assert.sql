\set ON_ERROR_STOP on
\echo 'Comprobando que el restore privado conserva inventario, propietarios y contenido sintéticos'

DO $$
DECLARE
  v_inventory issue52_rehearsal.inventory%ROWTYPE;
  v_board public.boards%ROWTYPE;
  v_admin issue52_rehearsal.bootstrap%ROWTYPE;
  v_count integer;
BEGIN
  IF (SELECT count(*) FROM issue52_rehearsal.inventory) <> 2 THEN
    RAISE EXCEPTION 'El restore perdió parte del inventario sintético';
  END IF;

  SELECT * INTO STRICT v_admin FROM issue52_rehearsal.bootstrap WHERE singleton;
  IF NOT EXISTS (
    SELECT 1 FROM public.application_access AS access
    WHERE access.email = v_admin.admin_email
      AND access.auth_user_id = v_admin.admin_id
      AND access.google_subject = v_admin.admin_subject
      AND access.state = 'active'
      AND access.is_admin
  ) THEN
    RAISE EXCEPTION 'El restore perdió la elección explícita del admin bootstrap';
  END IF;

  FOR v_inventory IN SELECT * FROM issue52_rehearsal.inventory ORDER BY slug LOOP
    SELECT * INTO STRICT v_board FROM public.boards WHERE id = v_inventory.board_id;
    IF v_board.slug IS DISTINCT FROM v_inventory.slug
      OR v_board.owner_id IS DISTINCT FROM v_inventory.explicit_owner_id THEN
      RAISE EXCEPTION 'El restore cambió el owner del tablero %', v_inventory.slug;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.board_memberships AS membership
      WHERE membership.board_id = v_board.id
        AND membership.user_id = v_inventory.explicit_owner_id
        AND membership.role = 'owner'
        AND membership.revoked_at IS NULL
    ) THEN
      RAISE EXCEPTION 'El restore perdió la membership dueña de %', v_inventory.slug;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.columns AS column_row
    WHERE column_row.board_id = v_board.id;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'El restore cambió el número de columnas de %', v_inventory.slug;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.columns AS column_row
    JOIN public.tasks AS task ON task.column_id = column_row.id
    WHERE column_row.board_id = v_board.id;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'El restore cambió el número de tareas de %', v_inventory.slug;
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM public.columns AS column_row
      JOIN public.tasks AS task ON task.column_id = column_row.id
      WHERE column_row.board_id = v_board.id
        AND task.id = v_inventory.expected_task_id
        AND task.title = v_inventory.expected_task_title
    ) THEN
      RAISE EXCEPTION 'El restore perdió contenido de %', v_inventory.slug;
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1 FROM public.board_memberships AS membership
    WHERE membership.board_id IN (SELECT board_id FROM issue52_rehearsal.inventory)
      AND membership.user_id = v_admin.admin_id
      AND membership.revoked_at IS NULL
  )
    OR has_function_privilege('anon', 'public.get_full_board_p(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'El restore otorgó acceso de tablero al admin bootstrap o reabrió RPC anónima';
  END IF;
END;
$$;

\echo 'PASS: el restore privado preserva owners/contenido y no convierte al admin en lector global.'
