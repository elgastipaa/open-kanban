# Issue tracker: GitHub

Repositorio de trabajo: `elgastipaa/open-kanban` (`origin`). Especificar este repositorio en las operaciones; `upstream` es el proyecto de referencia, no el destino de los tickets.

## Dónde vive cada cosa

- Las specs y tickets de trabajo publicados por estas skills viven en GitHub Issues.
- `docs/specs/` conserva los acuerdos, contratos y criterios existentes del producto. Los issues deben citar los documentos aplicables y reflejar sus decisiones vigentes.
- Al modificar una decisión, mantener coherencia entre issue y documento dueño; no mantener dos contratos divergentes.
- Al pedir una skill «publish to the issue tracker», crear o actualizar el issue correspondiente en este repositorio. Buscar primero uno existente para evitar duplicados.
- Al pedir «fetch the relevant ticket», leer el issue y los comentarios necesarios para entender su estado.

## Herramientas y operaciones

Preferir el conector de GitHub disponible. Cuando no cubra una operación, usar GitHub CLI autenticada si está disponible; si falta, informar esa limitación y utilizar una alternativa autorizada. No asumir que `gh` está instalada o autenticada.

En esta estación Windows, la CLI está disponible mediante `wsl.exe -d Ubuntu --exec gh ...`. Pasar siempre `--repo elgastipaa/open-kanban`; usar esa CLI para GitHub no cambia el checkout local de trabajo. Para `--body-file`, convertir la ruta Windows a una ruta accesible desde WSL.

Equivalentes CLI habituales, siempre con `--repo elgastipaa/open-kanban`:

- Leer: `gh issue view <number> --json number,title,body,labels,comments`.
- Listar: `gh issue list --state open --json number,title,body,labels,assignees`; paginar cuando se necesite el conjunto completo.
- Crear: `gh issue create --title <title> --body-file <path>`.
- Actualizar: `gh issue edit <number> --body-file <path>`.
- Comentar: `gh issue comment <number> --body-file <path>`.
- Etiquetar: `gh issue edit <number> --add-label <label>` o `--remove-label <label>`.
- Cerrar: `gh issue close <number>`.

Para textos multilínea, usar argumentos estructurados del conector o un archivo UTF-8 y `--body-file`. No construir comandos con el contenido del documento.

## Pull requests as a triage surface

**PRs as a request surface: no.**

GitHub comparte numeración entre issues y PRs; comprobar el tipo de una referencia antes de operar.

## Tareas, subtareas y dependencias

- `to-tickets`: un issue por tarea, vinculado a la spec origen. Usar sub-issues y dependencias nativas cuando estén disponibles.
- Si falta soporte de sub-issues, registrar `Part of #<parent>` en el hijo y enlazarlo desde el padre.
- Si faltan dependencias nativas, registrar `Blocked by: #<number>` y resolver el estado de cada bloqueador antes de comenzar.
- `wayfinder`: un issue mapa con notas, decisiones y preguntas abiertas, más issues hijos por investigación, prototipo, decisión o tarea. Aplicar las convenciones de esa skill cuando sea invocada.
- Elegir trabajo abierto, sin bloqueadores abiertos y sin otra persona asignada. Registrar la asignación antes de comenzar; al terminar, añadir evidencia, cerrar el hijo y actualizar el mapa.
- En APIs que exijan identificadores internos, obtener el ID real del issue: no sustituirlo por su número visible.

## Alcance de las acciones

La configuración del tracker y las etiquetas no autoriza por sí sola implementar, hacer commit/push ni desplegar. Aplicar las autorizaciones vigentes del proyecto y del pedido actual. La invocación explícita de una skill determina las operaciones que el usuario está solicitando.
