-- Compara roles/membresías y permisos por nombre; no serializa contraseñas.
SELECT 'role|' || role.rolname || '|' || role.rolsuper || '|' || role.rolinherit
  || '|' || role.rolcreaterole || '|' || role.rolcreatedb || '|' || role.rolcanlogin
  || '|' || role.rolreplication || '|' || role.rolbypassrls || '|' || role.rolconnlimit
  || '|' || coalesce(role.rolvaliduntil::text, '<none>')
FROM pg_roles AS role
ORDER BY role.rolname;

SELECT 'membership|' || member.rolname || '->' || granted_role.rolname
  || '|by:' || grantor.rolname
  || '|admin:' || membership.admin_option::text
  || '|inherit:' || membership.inherit_option::text
  || '|set:' || membership.set_option::text
FROM pg_auth_members AS membership
JOIN pg_roles AS granted_role ON granted_role.oid = membership.roleid
JOIN pg_roles AS member ON member.oid = membership.member
JOIN pg_roles AS grantor ON grantor.oid = membership.grantor
ORDER BY member.rolname, granted_role.rolname, grantor.rolname;

SELECT 'schema|' || namespace.nspname || '|' || pg_catalog.pg_get_userbyid(namespace.nspowner)
  || '|' || (
    SELECT coalesce(string_agg(
      CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END
        || '=' || acl.privilege_type || ':' || acl.is_grantable::text
        || ':by:' || pg_catalog.pg_get_userbyid(acl.grantor),
      ',' ORDER BY
        CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END,
        acl.privilege_type, pg_catalog.pg_get_userbyid(acl.grantor)
    ), '')
    FROM aclexplode(coalesce(namespace.nspacl, acldefault('n', namespace.nspowner))) AS acl
  )
FROM pg_namespace AS namespace
WHERE namespace.nspname !~ '^(pg_|information_schema$)'
  AND namespace.nspname <> 'extensions'
ORDER BY namespace.nspname;

SELECT 'relation|' || namespace.nspname || '.' || relation.relname || '|' || relation.relkind::text
  || '|' || pg_catalog.pg_get_userbyid(relation.relowner)
  || '|' || (
    SELECT coalesce(string_agg(
      CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END
        || '=' || acl.privilege_type || ':' || acl.is_grantable::text
        || ':by:' || pg_catalog.pg_get_userbyid(acl.grantor),
      ',' ORDER BY
        CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END,
        acl.privilege_type, pg_catalog.pg_get_userbyid(acl.grantor)
    ), '')
    FROM aclexplode(coalesce(
      relation.relacl,
      acldefault(CASE WHEN relation.relkind = 'S' THEN 'S'::"char" ELSE 'r'::"char" END, relation.relowner)
    )) AS acl
  )
  || '|' || relation.relrowsecurity || '|' || relation.relforcerowsecurity
FROM pg_class AS relation
JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
WHERE namespace.nspname !~ '^(pg_|information_schema$)'
  AND namespace.nspname <> 'extensions'
  AND relation.relkind IN ('r', 'p', 'S', 'v', 'm', 'f')
ORDER BY namespace.nspname, relation.relname;

SELECT 'routine|' || namespace.nspname || '.' || routine.proname || '|'
  || pg_catalog.pg_get_function_identity_arguments(routine.oid)
  || '|' || pg_catalog.pg_get_userbyid(routine.proowner)
  || '|' || (
    SELECT coalesce(string_agg(
      CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END
        || '=' || acl.privilege_type || ':' || acl.is_grantable::text
        || ':by:' || pg_catalog.pg_get_userbyid(acl.grantor),
      ',' ORDER BY
        CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END,
        acl.privilege_type, pg_catalog.pg_get_userbyid(acl.grantor)
    ), '')
    FROM aclexplode(coalesce(routine.proacl, acldefault('f', routine.proowner))) AS acl
  )
  || '|' || routine.prosecdef
FROM pg_proc AS routine
JOIN pg_namespace AS namespace ON namespace.oid = routine.pronamespace
WHERE namespace.nspname !~ '^(pg_|information_schema$)'
  AND namespace.nspname <> 'extensions'
ORDER BY namespace.nspname, routine.proname,
  pg_catalog.pg_get_function_identity_arguments(routine.oid);

SELECT 'policy|' || namespace.nspname || '.' || relation.relname || '.' || policy.polname
  || '|' || policy.polcmd::text
  || '|' || ARRAY(
    SELECT role.rolname
    FROM unnest(policy.polroles) AS role_id(oid)
    JOIN pg_roles AS role ON role.oid = role_id.oid
    ORDER BY role.rolname
  )::text
  || '|' || coalesce(pg_catalog.pg_get_expr(policy.polqual, policy.polrelid), '<none>')
  || '|' || coalesce(pg_catalog.pg_get_expr(policy.polwithcheck, policy.polrelid), '<none>')
FROM pg_policy AS policy
JOIN pg_class AS relation ON relation.oid = policy.polrelid
JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
WHERE namespace.nspname !~ '^(pg_|information_schema$)'
  AND namespace.nspname <> 'extensions'
ORDER BY namespace.nspname, relation.relname, policy.polname;

SELECT 'default_acl|' || coalesce(namespace.nspname, '<database>') || '|'
  || pg_catalog.pg_get_userbyid(default_acl.defaclrole) || '|'
  || default_acl.defaclobjtype::text || '|' || (
    SELECT coalesce(string_agg(
      CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END
        || '=' || acl.privilege_type || ':' || acl.is_grantable::text
        || ':by:' || pg_catalog.pg_get_userbyid(acl.grantor),
      ',' ORDER BY
        CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_catalog.pg_get_userbyid(acl.grantee) END,
        acl.privilege_type, pg_catalog.pg_get_userbyid(acl.grantor)
    ), '')
    FROM aclexplode(default_acl.defaclacl) AS acl
  )
FROM pg_default_acl AS default_acl
LEFT JOIN pg_namespace AS namespace ON namespace.oid = default_acl.defaclnamespace
ORDER BY namespace.nspname, default_acl.defaclrole, default_acl.defaclobjtype;
