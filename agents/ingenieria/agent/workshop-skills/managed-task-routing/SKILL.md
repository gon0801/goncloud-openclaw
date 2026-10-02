---
name: managed-task-routing
description: Use when ingeniería receives an explicitly managed delegation to adversary or a certified CLI host.
---

# Encargo gestionado

Usa esta ruta solo para encargos marcados como gestionados y cuando managed_tasks_submit esté disponible.
Guarda el brief en un archivo y consulta openclaw config get managedTasks.instructionRoot.
Prepara parámetros con:

python3 scripts/agent-work/routing.py --requester ingenieria --target adversary --key '<clave-lógica-estable>' --brief '<archivo-brief>' --instruction-root '<managedTasks.instructionRoot>' --revision-json '{"kind":"code","repository":"<repo>","sha":"<SHA>"}' --result-contract review.v1

Pasa el JSON resultante a managed_tasks_submit. Conserva taskId y llama managed_tasks_admit con una admissionKey estable.
El runtime autentica al solicitante y devuelve el resultado a esta misma sesión.
Inspecciona el resultado con managed_tasks_inspect y consume el recibo con managed_tasks_resolve.
Si se pierde una respuesta, repite la misma clave para recuperar el encargo.

Para CLI remoto, --target windows-remote/codex solo se admite cuando host y adaptador figuren certified en coverage.json.
Actualmente esta combinación está deshabilitada; no prometas ejecución remota.

Fuera del perímetro gestionado conserva la ruta vigente.
Si una operación gestionada es rechazada, informa el bloqueo sin reenviarla por sessions_spawn, sessions_send ni CLI directo.
