---
name: poteto-mausbot
description: Léela antes de poteto-mode cuando hagas trabajo de ingeniería, revisión o verificación en OpenMausBot. Traduce a MausBot las herramientas que nombra poteto.
---

# poteto en MausBot

`poteto-mode` y las `principle-*` están entre tus skills. En MausBot cada skill es un solo `SKILL.md`, así que los playbooks y references de poteto no vienen como archivos aparte. Si `poteto-mode` nombra un playbook, usa sus pasos como referencia y dilo. Lo que poteto nombra, aquí:

- Leer una skill: la herramienta de lectura de tu motor.
- La lista de pasos de un playbook va en la lista de tareas de tu motor. Su primer paso es el primer paso del playbook, con sus palabras.
- Delegar en otros bots: `list_bots` para descubrir sus ids y `coordinate_bots` con uno a cuatro `bot_ids`. Manda rutas exactas, restricciones y `done_when`. Después termina tu turno, porque el resultado vuelve solo y te reanuda. No hagas polling ni llames `assignment_status` en el mismo turno.
- Consultar a un bot sin darle trabajo: `coordinate_bots` con `consult: true`. Un aviso de una sola vía: `reply: "none"`.
- Preguntar por trabajo pendiente: `assignment_status` en un turno posterior, no para esperar dentro del turno.
- Correr pruebas y comandos, editar y escribir: las herramientas nativas de tu motor, con los permisos del bot.
- Un bot no puede delegar en quien le asignó el trabajo ni en alguien por encima. Para reportar, termina el turno y deja que tu respuesta lo reanude.
- Para trabajo de computadora, `select_computer` elige la computadora. No vuelvas a las herramientas viejas después de pedir el cambio.

Dentro de un encargo del motor, esta adaptación manda sobre el poteto original donde chocan:

- El implementador usa poteto-mode. Sharpen, Architect, Arena y Figure-it-out se usan cuando el trabajo los necesita. No son una cadena obligatoria.
- No hace falta un runbook previo ni campos de aceptación para empezar.
- No hay un juez adicional de bitácora. Decisión, motivo, evidencia y resultado salen del registro del encargo.
- Una nota de redacción o de documentación menor no devuelve el trabajo.
- Una hipótesis del plan no es una prohibición expresa del propietario.

El paquete original de poteto se conserva. Estas líneas son la diferencia. No reescriben sus skills.
