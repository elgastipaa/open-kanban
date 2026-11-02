\set ON_ERROR_STOP on
\echo 'Issue #21: personal board favorites are idempotent and membership-scoped'

CREATE TEMP TABLE issue21_favorite_fixture (
  label text PRIMARY KEY,
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  collaborator_membership_id uuid
);
GRANT SELECT, INSERT, UPDATE ON issue21_favorite_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
BEGIN
  SELECT * INTO STRICT v_board
  FROM public.create_board_p(
    'Issue 21 favorite board A',
    'UTC',
    'a7210000-0000-4000-8000-000000000001'
  );
  INSERT INTO pg_temp.issue21_favorite_fixture(label, board_id, board_slug)
  VALUES ('board_a', v_board.id, v_board.slug);
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
DECLARE
  v_board record;
BEGIN
  SELECT * INTO STRICT v_board
  FROM public.create_board_p(
    'Issue 21 favorite board B',
    'UTC',
    'a7210000-0000-4000-8000-000000000002'
  );
  INSERT INTO pg_temp.issue21_favorite_fixture(label, board_id, board_slug)
  VALUES ('board_b', v_board.id, v_board.slug);
END;
$$;
COMMIT;

WITH added_membership AS (
  INSERT INTO public.board_memberships(board_id, user_id, role)
  SELECT board_a.board_id, '40000000-0000-4000-8000-000000000005', 'collaborator'
  FROM pg_temp.issue21_favorite_fixture AS board_a
  WHERE board_a.label = 'board_a'
  RETURNING id, board_id
)
UPDATE pg_temp.issue21_favorite_fixture AS fixture
SET collaborator_membership_id = added_membership.id
FROM added_membership
WHERE fixture.label = 'board_a'
  AND fixture.board_id = added_membership.board_id;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board_a uuid;
  v_board_b uuid;
  v_result boolean;
  v_denied boolean := false;
  v_favorites uuid[];
BEGIN
  SELECT board_id INTO STRICT v_board_a
  FROM pg_temp.issue21_favorite_fixture WHERE label = 'board_a';
  SELECT board_id INTO STRICT v_board_b
  FROM pg_temp.issue21_favorite_fixture WHERE label = 'board_b';

  v_result := public.set_board_favorite_p(v_board_a, true);
  IF v_result IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Setting a favorite did not confirm the requested state';
  END IF;
  v_result := public.set_board_favorite_p(v_board_a, true);
  IF v_result IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Repeating a favorite request did not remain confirmed';
  END IF;

  SELECT array_agg(favorite.board_id ORDER BY favorite.board_id)
  INTO v_favorites
  FROM public.list_my_board_favorites_p() AS favorite;
  IF v_favorites IS DISTINCT FROM ARRAY[v_board_a] THEN
    RAISE EXCEPTION 'The first user did not read only their own favorite: %', v_favorites;
  END IF;

  BEGIN
    PERFORM public.set_board_favorite_p(v_board_b, true);
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A non-member could favorite a board by manipulating its ID';
  END IF;

  SELECT array_agg(favorite.board_id ORDER BY favorite.board_id)
  INTO v_favorites
  FROM public.list_my_board_favorites_p() AS favorite;
  IF v_favorites IS DISTINCT FROM ARRAY[v_board_a] THEN
    RAISE EXCEPTION 'A denied cross-board request changed the first user’s favorites';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
DECLARE
  v_board_a uuid;
  v_board_b uuid;
  v_result boolean;
  v_favorites uuid[];
BEGIN
  SELECT board_id INTO STRICT v_board_a
  FROM pg_temp.issue21_favorite_fixture WHERE label = 'board_a';
  SELECT board_id INTO STRICT v_board_b
  FROM pg_temp.issue21_favorite_fixture WHERE label = 'board_b';
  v_result := public.set_board_favorite_p(v_board_b, true);
  IF v_result IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'The second user could not favorite their own board';
  END IF;
  v_result := public.set_board_favorite_p(v_board_b, true);
  IF v_result IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Repeating the second user’s favorite request was not idempotent';
  END IF;

  SELECT array_agg(favorite.board_id ORDER BY favorite.board_id)
  INTO v_favorites
  FROM public.list_my_board_favorites_p() AS favorite;
  IF v_favorites IS DISTINCT FROM ARRAY[v_board_b] THEN
    RAISE EXCEPTION 'The second user saw another person’s favorite: %', v_favorites;
  END IF;

  v_result := public.set_board_favorite_p(v_board_a, true);
  IF v_result IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'A current collaborator could not favorite an accessible board';
  END IF;
  v_result := public.set_board_favorite_p(v_board_a, false);
  IF v_result IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Removing a favorite did not confirm the requested state';
  END IF;
  v_result := public.set_board_favorite_p(v_board_a, false);
  IF v_result IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Repeating favorite removal was not idempotent';
  END IF;
  v_result := public.set_board_favorite_p(v_board_a, true);
  IF v_result IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Retrying a favorite set did not recover the requested state';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
DECLARE
  v_board_a uuid;
  v_board_b uuid;
  v_favorites uuid[];
BEGIN
  SELECT board_id INTO STRICT v_board_a
  FROM pg_temp.issue21_favorite_fixture WHERE label = 'board_a';
  SELECT board_id INTO STRICT v_board_b
  FROM pg_temp.issue21_favorite_fixture WHERE label = 'board_b';
  SELECT array_agg(favorite.board_id ORDER BY favorite.board_id)
  INTO v_favorites
  FROM public.list_my_board_favorites_p() AS favorite;
  IF coalesce(cardinality(v_favorites), 0) <> 2
    OR NOT (v_board_a = ANY(v_favorites))
    OR NOT (v_board_b = ANY(v_favorites)) THEN
    RAISE EXCEPTION 'A second request did not read the persisted favorites: %', v_favorites;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board_a uuid;
  v_membership_id uuid;
BEGIN
  SELECT board_id INTO STRICT v_board_a
  FROM pg_temp.issue21_favorite_fixture WHERE label = 'board_a';
  SELECT collaborator_membership_id INTO STRICT v_membership_id
  FROM pg_temp.issue21_favorite_fixture WHERE label = 'board_a';

  IF (public.remove_board_collaborator_p(
    'a7210000-0000-4000-8000-000000000003',
    v_board_a,
    v_membership_id
  )->>'status') IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The owner could not revoke the test collaborator';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
DECLARE
  v_board_a uuid;
  v_board_b uuid;
  v_favorites uuid[];
BEGIN
  SELECT board_id INTO STRICT v_board_a
  FROM pg_temp.issue21_favorite_fixture WHERE label = 'board_a';
  SELECT board_id INTO STRICT v_board_b
  FROM pg_temp.issue21_favorite_fixture WHERE label = 'board_b';
  IF EXISTS (
    SELECT 1 FROM public.list_my_boards() AS board WHERE board.id = v_board_a
  ) OR NOT EXISTS (
    SELECT 1 FROM public.list_my_boards() AS board WHERE board.id = v_board_b
  ) THEN
    RAISE EXCEPTION 'The board list did not hide only the revoked board';
  END IF;

  BEGIN
    PERFORM public.set_board_favorite_p(v_board_a, false);
    RAISE EXCEPTION 'The revoked collaborator could still mutate its old favorite';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  SELECT array_agg(favorite.board_id ORDER BY favorite.board_id)
  INTO v_favorites
  FROM public.list_my_board_favorites_p() AS favorite;
  IF v_favorites IS DISTINCT FROM ARRAY[v_board_b] THEN
    RAISE EXCEPTION 'A revoked board remained visible in Favorites: %', v_favorites;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board_a uuid;
  v_board_b uuid;
  v_favorites uuid[];
BEGIN
  SELECT board_id INTO STRICT v_board_a
  FROM pg_temp.issue21_favorite_fixture WHERE label = 'board_a';
  SELECT board_id INTO STRICT v_board_b
  FROM pg_temp.issue21_favorite_fixture WHERE label = 'board_b';
  SELECT array_agg(favorite.board_id ORDER BY favorite.board_id)
  INTO v_favorites
  FROM public.list_my_board_favorites_p() AS favorite;
  IF v_favorites IS DISTINCT FROM ARRAY[v_board_a] THEN
    RAISE EXCEPTION 'Revoking another person did not preserve the owner’s personal favorite';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.list_my_boards() AS board WHERE board.id = v_board_b
  ) OR NOT EXISTS (
    SELECT 1 FROM public.list_my_boards() AS board WHERE board.id = v_board_a
  ) THEN
    RAISE EXCEPTION 'The first user’s board list crossed membership boundaries';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board_a uuid;
  v_denied boolean := false;
BEGIN
  SELECT board_id INTO STRICT v_board_a
  FROM pg_temp.issue21_favorite_fixture WHERE label = 'board_a';
  BEGIN
    PERFORM public.set_board_favorite_p(v_board_a, true);
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A global administrator without membership could favorite a board';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_board_a uuid;
  v_list_denied boolean := false;
  v_set_denied boolean := false;
BEGIN
  SELECT board_id INTO STRICT v_board_a
  FROM pg_temp.issue21_favorite_fixture WHERE label = 'board_a';
  BEGIN
    PERFORM 1 FROM public.list_my_board_favorites_p();
  EXCEPTION WHEN insufficient_privilege THEN
    v_list_denied := true;
  END;
  BEGIN
    PERFORM public.set_board_favorite_p(v_board_a, true);
  EXCEPTION WHEN insufficient_privilege THEN
    v_set_denied := true;
  END;
  IF NOT v_list_denied OR NOT v_set_denied THEN
    RAISE EXCEPTION 'An account without application access could read or change favorites';
  END IF;
END;
$$;
COMMIT;

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.board_favorites', 'SELECT')
    OR has_table_privilege('authenticated', 'public.board_favorites', 'INSERT')
    OR has_table_privilege('authenticated', 'public.board_favorites', 'UPDATE')
    OR has_table_privilege('authenticated', 'public.board_favorites', 'DELETE')
    OR has_table_privilege('anon', 'public.board_favorites', 'SELECT')
    OR has_function_privilege('anon', 'public.list_my_board_favorites_p()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Authenticated clients can bypass the favorite RPC through the table';
  END IF;
END;
$$;

\echo 'PASS: favorites are personal, idempotent, and hidden when membership is revoked'
