\set ON_ERROR_STOP on
\echo 'Comprobando que el restore privado conserva inventario, propietarios y contenido sintéticos'
\ir issue52_inventory_assert.sql

\echo 'PASS: el restore privado preserva owners/contenido y no convierte al admin en lector global.'
