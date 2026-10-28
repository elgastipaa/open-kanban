# OpenKanban — instrucciones para agentes

Antes de cambiar alcance o iniciar implementación, leer `docs/specs/CONTINUIDAD-SPEC.md` y los acuerdos relevantes de `docs/specs/0001-auth-collaboration.md`. La fase y autorizaciones vigentes se obtienen de ese checkpoint y de las instrucciones actuales del usuario.

## Agent skills

### Implementación en loop

Antes de seleccionar tickets, reanudar un run o cerrar entregas de implementación, leer `docs/agents/implementation-loop.md`. LP-0.2 define un Goal continuo con GPT Luna Max, `implement-spec` secuencial e `implement` por ticket; comprobar la autorización de arranque en Continuidad. Para el comando, consultar `docs/agents/start-implementation-goal.md`.

### Issue tracker

Specs de trabajo y tickets en GitHub Issues de `elgastipaa/open-kanban`. Antes de leer, publicar o actualizar tickets, consultar `docs/agents/issue-tracker.md`.

### Triage labels

Cinco estados de clasificación con nombres predeterminados. Antes de clasificar tickets, consultar `docs/agents/triage-labels.md`.

### Domain docs

Un único contexto de dominio. Antes de explorar o diseñar una funcionalidad, consultar `docs/agents/domain.md` para localizar glosario, acuerdos y decisiones relevantes.
