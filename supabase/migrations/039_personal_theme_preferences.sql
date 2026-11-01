BEGIN;

CREATE TABLE public.user_preferences (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  preference_key text NOT NULL
    CHECK (preference_key ~ '^[a-z][a-z0-9_]{0,63}$'),
  value jsonb NOT NULL,
  version integer NOT NULL DEFAULT 1 CHECK (version > 0),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (user_id, preference_key),
  CONSTRAINT user_preferences_theme_value CHECK (
    preference_key <> 'theme'
    OR value IN ('"system"'::jsonb, '"light"'::jsonb, '"dark"'::jsonb)
  )
);

ALTER TABLE public.user_preferences ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.user_preferences
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.get_my_theme_preference_p()
RETURNS TABLE(theme text, version integer)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    coalesce(preference.value #>> '{}', 'system'),
    coalesce(preference.version, 0)
  FROM (VALUES (1)) AS default_row(singleton)
  LEFT JOIN public.user_preferences AS preference
    ON preference.user_id = auth.uid()
    AND preference.preference_key = 'theme';
END;
$$;
REVOKE ALL ON FUNCTION public.get_my_theme_preference_p()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_theme_preference_p() TO authenticated;

CREATE FUNCTION public.set_my_theme_preference_p(
  p_theme text,
  p_expected_version integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_saved_version integer;
  v_saved_theme text;
  v_current_version integer;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
  END IF;
  IF p_theme IS NULL
    OR p_theme NOT IN ('system', 'light', 'dark')
    OR p_expected_version IS NULL
    OR p_expected_version < 0 THEN
    RAISE EXCEPTION 'A supported theme and version are required'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.user_preferences AS current_preference (
    user_id,
    preference_key,
    value,
    version,
    updated_at
  )
  SELECT
    v_actor_id,
    'theme',
    to_jsonb(p_theme),
    1,
    clock_timestamp()
  WHERE p_expected_version = 0
    OR EXISTS (
      SELECT 1
      FROM public.user_preferences AS existing_preference
      WHERE existing_preference.user_id = v_actor_id
        AND existing_preference.preference_key = 'theme'
    )
  ON CONFLICT (user_id, preference_key) DO UPDATE
  SET value = EXCLUDED.value,
      version = current_preference.version + 1,
      updated_at = clock_timestamp()
  WHERE current_preference.version = p_expected_version
  RETURNING version INTO v_saved_version;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'status', 'saved',
      'theme', p_theme,
      'version', v_saved_version
    );
  END IF;

  SELECT preference.value #>> '{}', preference.version
  INTO v_saved_theme, v_current_version
  FROM public.user_preferences AS preference
  WHERE preference.user_id = v_actor_id
    AND preference.preference_key = 'theme';

  RETURN jsonb_build_object(
    'status', 'conflict',
    'theme', coalesce(v_saved_theme, 'system'),
    'version', coalesce(v_current_version, 0)
  );
END;
$$;
REVOKE ALL ON FUNCTION public.set_my_theme_preference_p(text, integer)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_my_theme_preference_p(text, integer)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
