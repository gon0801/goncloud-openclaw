# Ensayo de adopción de encargos

Estado: preparación de T11. B4 sigue abierto y no existe todavía un paquete nativo final comprobado. `cutover.py` funciona solo con `--simulation`; no instala un binario, modifica cron ni habla con un Gateway. El operador debe completar T11 con el artefacto y los comandos reales de T0 antes de pedir autorización para T12.

## Contrato del ensayo

El manifiesto de prueba fija `sourceSha`, ruta absoluta y SHA-256 del paquete y `schemaCompatibility`. `prepare` comprueba ese paquete, exige admisión congelada y captura activa, y fija el digest del manifiesto junto con la siguiente generación. `inspect` muestra el estado guardado. `apply` exige un registro de autorización que coincida con digest, alcance, generación y operación. Rechaza dos emisores, admisión incierta, cron no suspendido, turnos de cron en vuelo y peticiones del cron después de suspenderlo. Al transferir, conserva sesiones y resultados pendientes. `rollback` congela primero la admisión. Solo cambia binario y configuración de la simulación si el esquema sigue siendo legible por el binario anterior. Conserva la captura y el cron suspendido incluso tras una reversa satisfactoria.

El JSON de simulación es una observación inyectada, no un mecanismo de control para servicios reales. La prueba de dos emisores representa una anomalía que impide transferir la propiedad. En producción se necesita una lectura independiente del estado de cron, los emisores y las admisiones, más una operación real de suspensión y drenaje. No basta con editar el JSON.

## Ensayo ejecutable

Desde la raíz de G:

```sh
bash scripts/tests/test-agent-work-cutover.sh
bash scripts/tests/test-instalar-mac.sh
```

La primera prueba comprueba la sintaxis de las herramientas de empaquetado. Después corre dos suites. `test_agent_work_cutover.py` usa archivos temporales como dobles de paquete, estado y autorización, y espera `6` casos en verde. `test_agent_work_artifact.py` comprueba con paquetes y un repo de R de prueba que el verificador del manifiesto rechaza hashes, commits de build, `entry.js` y esquemas que no son los registrados, y espera `12` casos: en el host de build los 12 en verde; fuera de él, 11 en verde y 1 saltado (`test_the_repo_manifest_matches_the_reviewed_runtime`, porque los paquetes viven en el host de build). Comprueba el cron antiguo suspendido sin turnos en vuelo ni peticiones posteriores, un solo propietario, resultados capturados, sesión intacta, admisión incierta, hash alterado y dos fallos de reversa. La segunda prueba instala los archivos de host en un `HOME` temporal y verifica su contenido. Espera `OK test-instalar-mac`. Tiempo máximo previsto para ambas en el host de ensayo: 60 segundos. Si falla cualquiera, detén la preparación y conserva los temporales de reproducción con datos no privados; no avances a T12.

## Condiciones pendientes para operación real

B4 cerró (PR #251). T11-a dejó el paquete de R `818f0fd` construido y verificado por `artifact-manifest.json` (`artifact.py verify`), con la base de estado de 19 a 27 y el binario anterior incapaz de abrirla, y los comandos medidos en `deploy-commands.md`. `limits.json` ya trae un perfil productivo medido, pero `maxContextTokens` es desconocido: R lo aplica a bytes del cuerpo HTTP y la copia no los guarda. Por eso `productionAdmissionEnabled` sigue en `false`, y `artifact.limit_problems` rechaza habilitarlo mientras haya un valor `null`. Después se ensaya instalación y reversa del binario y configuración sobre un entorno aislado que ejecute el Gateway real. La reversa incompatible conserva el binario nuevo, admisión congelada y resultados pendientes. Ningún procedimiento reactiva el cron antiguo automáticamente.

## Corte real (T11-b)

`scripts/agent-work/cutover_live.py prepare|inspect|apply --state <archivo> [--entry <entry.json>] [--limits <limits.json>] [--wait-seconds N]` hace el corte de una entrada contra el gateway con `openclaw gateway call` (`OPENCLAW_BIN`). La entrada nombra sus crons viejos, el host y el adaptador, su `deviceId` e `instructionRoot`, y los spools del host. `apply` se niega sin tocar nada ante dos emisores, una admisión incierta, un turno del cron en vuelo, límites desconocidos o datos faltantes. Si no, drena y suspende el cron viejo y abre la ruta nativa con generación nueva. El cambio de `managedTasks` reinicia el gateway, unos 6 s: `apply` lo espera, y un corte interrumpido se retoma con el mismo comando. La prueba es `bash scripts/tests/test-agent-work-e2e.sh cutover_fencing` (necesita `AGENT_WORK_RUNTIME_SOURCE`). El ensayo con una copia del gateway vivo se arma con `scripts/agent-work/runtime/ensayo-gateway.sh <copia> <prefijo> [puerto]`. Las mediciones y los resultados están en `T11.md`, sección T11-b.
