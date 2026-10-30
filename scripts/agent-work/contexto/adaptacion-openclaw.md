---
name: poteto-openclaw
description: Léela antes de poteto-mode cuando hagas trabajo de ingeniería, revisión o verificación en OpenClaw. Traduce a OpenClaw las herramientas que nombra poteto.
---

# poteto en OpenClaw

poteto (`poteto-mode`, sus playbooks y references, y las `principle-*`) está entre tus skills. Léela con `read` en su ruta y sigue su playbook. Lo que poteto nombra, aquí:

- Leer una skill, un playbook o una reference: `read` en su ruta.
- Siempre, también en una tarea chica: en `poteto-mode` elige el playbook de tu tarea (`playbooks/bug-fix.md` para arreglar algo, `playbooks/feature.md` para algo nuevo, o el que `poteto-mode` indique) y léelo con `read` en su ruta antes de tu primer cambio.
- La lista de pasos del playbook: `progress_card`. Puede no estar a la vista: búscala con `tool_search` (por ejemplo "progress card") y ábrela antes de tu primer cambio, con los pasos del playbook copiados tal cual. Su primer paso es el primer paso del playbook, con sus palabras.
- Delegar: `sessions_spawn`. Empieza el `task` con `profile: <id>`, el perfil del hijo.
- Correr pruebas y comandos: `exec`. Editar: `edit`, `write` o `apply_patch`, solo si tu perfil escribe fuente.
- Una skill que no está entre las tuyas no está disponible. Si poteto pide una, dilo en tu respuesta y sigue sin ella.

Dentro de un encargo del motor, esta adaptación manda sobre el poteto original donde chocan:

- El implementador usa poteto-mode. Sharpen, Architect, Arena y Figure-it-out no son una cadena obligatoria para cualquier pedido.
- No hace falta un runbook previo ni campos de aceptación para empezar.
- No hay un juez adicional de bitácora. Decisión, motivo, evidencia y resultado salen del registro del encargo.
- Una nota de redacción o de documentación menor no devuelve el trabajo.
- Una hipótesis del plan no es una prohibición expresa del propietario.
- No asumas Cursor ni abras otro revisor DeepSeek fuera de `goncloud-pr-review`.

El paquete original de poteto se conserva. Estas líneas son la diferencia; no reescriben sus skills.
