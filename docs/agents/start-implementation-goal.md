# Iniciar el Goal de implementación

Fecha28/10/2026. Complemento de [LP-0.2](./implementation-loop.md); no es una skill nueva ni una activación automática.

## Antes de enviarlo

Usar un chat local del proyecto que apunte al checkout de integración C:/Users/gasto/Documents/GitHub/open-kanban. El Goal de este run ya existe; consultar su estado actual y [su checkpoint](./implementation-run.md) antes de iniciar otra ejecución. La base documental ya está versionada en1aea3ef sobre codex/openkanban-1-0: crear los worktrees desde la integración vigente para incluirla. Preservar docs/VALIDATION.md y otros cambios ajenos.

Elegir en el selector **GPT Luna** y razonamiento **Max**. El texto del Goal expresa la elección, pero no reemplaza cambiar el selector ni acredita que el modelo actual ya cambió. Heredar la misma selección en implementadores/merger/revisores; sin fallback a otro modelo.

## Comando para el chat de Codex

Para un arranque nuevo, pegar el mensaje completo siguiente en el chat, no en PowerShell. Al enviarlo, el usuario activa el Goal y autoriza las operaciones enumeradas dentro de sus límites. El comando ya fue enviado para el run actual; revalidar su estado en vez de crear otro Goal.

```text
/goal Implementar completa la spec https://github.com/elgastipaa/open-kanban/issues/2 y resolver sus tickets #3–#53 siguiendo AGENTS.md y docs/agents/implementation-loop.md (LP-0.2). Usar GPT Luna con razonamiento Max, $implement-spec como coordinador secuencial y $implement en cada ticket, con $tdd y $code-review. Mantener un único implementador activo y continuar automáticamente al siguiente elegible sin pedirme “seguí” ni detenerse al cerrar un ticket. Autorizo implementación y pruebas aisladas, ramas codex/, commits, push de esas ramas, PR acumulada en borrador y seguimiento/cierre de hijos solo con evidencia. Preservar cambios ajenos y todas las P/E. No hacer merge/push a main ni migrar/desplegar producción sin aprobación específica. Si un ticket se bloquea, continuar con otros elegibles; si no queda trabajo alcanzable, informar bloqueo real sin marcar completo el objetivo. El #53 conserva su aprobación de corte.
```

## Qué significa continuo

El coordinador sigue el grafo de bloqueos y aplica implement por ticket; completar una entrega no termina el Goal. Se conserva trabajo y evidencia entre turnos, con un único implementador activo. No requiere que el usuario envíe “seguí” entre tickets. El uso secuencial prevalece sobre la concurrencia predeterminada de implement-spec; TDD utiliza las tres interfaces previamente aprobadas sin volver a consultarlas en cada ticket.

No puede reemplazar una prueba manual obligatoria, configuración faltante ni aprobación de producción por texto en un prompt. Si #53 necesita aprobación de corte, queda pendiente y el Goal global no se declara completo. Hacer antes todo el trabajo independiente alcanzable.

Según [OpenAI Docs sobre Goals](https://developers.openai.com/cookbook/examples/codex/using_goals_in_codex), la continuidad depende de un Goal activo y sus límites; /goal inspecciona, /goal pause pausa y /goal resume reanuda uno pausado. [Disponibilidad de comandos](https://developers.openai.com/blog/mastering-codex-remote-for-engineering) puede depender del host/build/configuración. Si /goal no aparece, informar esa diferencia; no instalar otro runner ni automatización por suposición.

La redacción del comando no cambia modelo/settings globales. El run actual comenzó por la instrucción explícita posterior del usuario y su ejecución se registra en el checkpoint.
