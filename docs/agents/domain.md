# Domain Docs

## Antes de explorar o diseñar

1. Leer `CONTEXT.md` en la raíz: es el glosario vigente de OpenKanban. Usar sus términos y distinciones.
2. Consultar `docs/specs/CONTINUIDAD-SPEC.md` para ubicar la versión vigente y el documento dueño de cada contrato.
3. Para requisitos de producto, leer los acuerdos relevantes de `docs/specs/0001-auth-collaboration.md` y el contrato correspondiente en MVP, Pantallas, Matriz de permisos o Estados y errores.
4. Leer los ADR relevantes de `docs/adr/` cuando existan. Si todavía no existen, continuar con los acuerdos documentados.

## Estructura

Un único contexto de dominio para la aplicación. `CONTEXT.md` cumple actualmente la función que las skills llaman `GLOSSARY.md`; conservarlo como fuente única y no duplicar sus definiciones. No hay división por contextos ni `GLOSSARY-MAP.md`.

Los ADR futuros viven en `docs/adr/` y documentan decisiones arquitectónicas cuando se resuelven; esta configuración no crea decisiones ficticias ni convierte todos los acuerdos funcionales en ADR.

## Uso y precedencia

- Nombrar conceptos según el glosario: tablero, columna, tarea, responsable, serie y ocurrencia tienen significados distintos.
- Si falta un término, señalar el hueco cuando sea necesario y resolverlo en el glosario vigente.
- Un acuerdo explícito posterior prevalece sobre antecedentes contradictorios. Distinguir alcance aprobado de mecanismos todavía pendientes y de funcionalidad ya implementada.
- Si una propuesta contradice un acuerdo o ADR, identificar la contradicción antes de cambiarlo.
- Las referencias de productos externos son evidencia de investigación; no amplían automáticamente el alcance.
