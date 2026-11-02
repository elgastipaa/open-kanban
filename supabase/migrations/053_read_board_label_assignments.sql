BEGIN;

CREATE FUNCTION public.get_board_label_assignments_p(p_slug text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board public.boards%ROWTYPE;
  v_tasks jsonb;
  v_birthdays jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user() THEN
    RETURN jsonb_build_object(
      'status', 'unavailable', 'tasks', '[]'::jsonb, 'birthdays', '[]'::jsonb
    );
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'status', 'unavailable', 'tasks', '[]'::jsonb, 'birthdays', '[]'::jsonb
    );
  END IF;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object('task_id', grouped.task_id, 'labels', grouped.labels)
      ORDER BY grouped.task_id
    ),
    '[]'::jsonb
  ) INTO v_tasks
  FROM (
    SELECT assignment.task_id,
      jsonb_agg(
        jsonb_build_object(
          'id', label.id,
          'board_id', label.board_id,
          'name', label.name,
          'color', label.color,
          'version', label.version
        ) ORDER BY label.created_at, label.id
      ) AS labels
    FROM public.board_label_task_assignments AS assignment
    JOIN public.board_labels AS label
      ON label.id = assignment.label_id
      AND label.board_id = assignment.board_id
      AND label.generation_id = assignment.generation_id
      AND label.deleted_at IS NULL
    JOIN public.tasks AS task ON task.id = assignment.task_id
    JOIN public.columns AS column_row ON column_row.id = task.column_id
    WHERE assignment.board_id = v_board.id
      AND assignment.generation_id = v_board.active_generation_id
      AND column_row.board_id = v_board.id
      AND column_row.generation_id = v_board.active_generation_id
    GROUP BY assignment.task_id
  ) AS grouped;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object('birthday_id', grouped.birthday_id, 'labels', grouped.labels)
      ORDER BY grouped.birthday_id
    ),
    '[]'::jsonb
  ) INTO v_birthdays
  FROM (
    SELECT assignment.birthday_id,
      jsonb_agg(
        jsonb_build_object(
          'id', label.id,
          'board_id', label.board_id,
          'name', label.name,
          'color', label.color,
          'version', label.version
        ) ORDER BY label.created_at, label.id
      ) AS labels
    FROM public.board_label_birthday_assignments AS assignment
    JOIN public.board_labels AS label
      ON label.id = assignment.label_id
      AND label.board_id = assignment.board_id
      AND label.generation_id = assignment.generation_id
      AND label.deleted_at IS NULL
    JOIN public.board_birthdays AS birthday ON birthday.id = assignment.birthday_id
    WHERE assignment.board_id = v_board.id
      AND assignment.generation_id = v_board.active_generation_id
      AND birthday.board_id = v_board.id
      AND birthday.generation_id = v_board.active_generation_id
    GROUP BY assignment.birthday_id
  ) AS grouped;

  RETURN jsonb_build_object(
    'status', 'available',
    'tasks', v_tasks,
    'birthdays', v_birthdays
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_board_label_assignments_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_board_label_assignments_p(text)
  TO authenticated;

COMMIT;
