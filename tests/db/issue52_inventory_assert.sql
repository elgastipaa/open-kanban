\set ON_ERROR_STOP on
\echo 'Comprobando inventario, identidades y owners explícitos del fixture #52'
\ir issue52_owner_map_assert.sql

DO $$
DECLARE
  v_inventory issue52_rehearsal.inventory%ROWTYPE;
  v_board public.boards%ROWTYPE;
  v_admin issue52_rehearsal.bootstrap%ROWTYPE;
  v_count integer;
BEGIN
  SELECT * INTO STRICT v_admin FROM issue52_rehearsal.bootstrap WHERE singleton;
  IF NOT EXISTS (
    SELECT 1 FROM public.application_access AS access
    WHERE access.email = v_admin.admin_email
      AND access.auth_user_id = v_admin.admin_id
      AND access.google_subject = v_admin.admin_subject
      AND access.state = 'active'
      AND access.is_admin
  ) THEN
    RAISE EXCEPTION 'El administrador bootstrap no coincide con la elección explícita del fixture';
  END IF;

  FOR v_inventory IN SELECT * FROM issue52_rehearsal.inventory ORDER BY slug LOOP
    SELECT * INTO STRICT v_board FROM public.boards WHERE id = v_inventory.board_id;
    IF v_board.slug IS DISTINCT FROM v_inventory.slug THEN
      RAISE EXCEPTION 'El tablero % no conserva su slug de inventario', v_inventory.slug;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.application_access AS access
      WHERE access.auth_user_id = v_inventory.explicit_owner_id
        AND access.state = 'active'
        AND NOT access.is_admin
    ) OR NOT EXISTS (
      SELECT 1 FROM public.board_memberships AS membership
      WHERE membership.board_id = v_board.id
        AND membership.user_id = v_inventory.explicit_owner_id
        AND membership.role = 'owner'
        AND membership.revoked_at IS NULL
    ) THEN
      RAISE EXCEPTION 'Falta la identidad habilitada o membresía dueña explícita para %', v_inventory.slug;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.columns AS column_row
    WHERE column_row.board_id = v_board.id;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'El tablero % cambió su número de columnas', v_inventory.slug;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.columns AS column_row
    JOIN public.tasks AS task ON task.column_id = column_row.id
    WHERE column_row.board_id = v_board.id;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'El tablero % cambió su número de tareas', v_inventory.slug;
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM public.columns AS column_row
      JOIN public.tasks AS task ON task.column_id = column_row.id
      WHERE column_row.board_id = v_board.id
        AND task.id = v_inventory.expected_task_id
        AND task.title = v_inventory.expected_task_title
    ) THEN
      RAISE EXCEPTION 'El ensayo perdió el contenido sintético de %', v_inventory.slug;
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1 FROM public.board_memberships AS membership
    WHERE membership.board_id IN (SELECT board_id FROM issue52_rehearsal.inventory)
      AND membership.user_id = v_admin.admin_id
      AND membership.revoked_at IS NULL
  ) OR has_function_privilege('anon', 'public.get_full_board_p(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'El admin bootstrap recibió membresía de tablero o se reabrió la RPC anónima';
  END IF;
END;
$$;

\echo 'PASS: inventario, contenido, owners y separación del admin bootstrap conservados.'
