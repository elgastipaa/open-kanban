\set ON_ERROR_STOP on
CREATE ROLE service_role NOLOGIN;
CREATE SCHEMA auth;
CREATE TABLE auth.users (
  id uuid PRIMARY KEY,
  email text UNIQUE NOT NULL,
  email_confirmed_at timestamptz,
  raw_app_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE TABLE auth.identities (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id),
  provider text NOT NULL,
  provider_id text NOT NULL,
  identity_data jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_sign_in_at timestamptz,
  UNIQUE (provider, provider_id)
);
CREATE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE
AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;

CREATE SCHEMA realtime;
CREATE TABLE realtime.messages (
  extension text NOT NULL,
  topic text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE FUNCTION realtime.topic() RETURNS text
LANGUAGE sql STABLE
AS $$
  SELECT nullif(current_setting('request.jwt.claim.topic', true), '');
$$;
GRANT USAGE ON SCHEMA realtime TO anon, authenticated, service_role;
GRANT SELECT, INSERT ON TABLE realtime.messages TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION realtime.topic() TO anon, authenticated, service_role;

-- An ownerless legacy board proves that importing URL knowledge grants nothing.
INSERT INTO public.boards (slug) VALUES ('closed-access-fixture');
INSERT INTO public.columns (board_id, title, position)
SELECT id, 'Confidencial', 0 FROM public.boards WHERE slug = 'closed-access-fixture';
INSERT INTO public.tasks (column_id, title, description, priority, position)
SELECT id, 'No visible para anónimos', 'fixture', 'medium', 0
FROM public.columns
WHERE board_id = (SELECT id FROM public.boards WHERE slug = 'closed-access-fixture');