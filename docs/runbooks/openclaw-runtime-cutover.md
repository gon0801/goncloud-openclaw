# Runbook: cutover del runtime OpenClaw (Fase 16.8, opera; 16.6 construye)

Opera el corte Windows de la separacion fuente/runtime. La ingenieria
(16.6, este PR) construye y prueba los scripts; la operacion (16.8) los
corre en el host vivo con una `authorization_ref` operacional DISTINTA de
la de implementacion. Sin esa autorizacion, este documento es lectura:
cada comando vivo lleva la marca `[authorization_ref]`.

Fuentes de verdad: plan `docs/superpowers/plans/2026-09-22-openclaw-runtime-separation.md`
(Tasks 7-8), diseno `docs/superpowers/specs/2026-09-22-openclaw-runtime-separation-design.md`,
y los scripts de `scripts/runtime-separation/` en el SHA de merge autorizado.
Ante contradiccion, manda el plan.

## 0. Autoridad y coordenadas fijas

- `authorization_ref` operacional nombra el SHA de merge EXACTO de la
  implementacion y cita CI, lector fresco, revisor independiente, Codex y
  lead vigentes para ese mismo SHA. Un SHA distinto, un `origin/main`
  avanzado o un checkout desalineado abortan antes de desplegar y exigen
  una autorizacion nueva; jamas fast-forward bajo la vieja.
- OpenClaw del host: `2026.9.5` exacto.
- Raices canonicas: fuente `C:\Users\ehven\src\goncloud-openclaw`,
  runtime `C:\Users\ehven\.openclaw`, nodo `C:\Users\ehven\.openclaw-node`,
  cutover `C:\Users\ehven\.openclaw-cutover`.
- Todo script corre desde el checkout fuente dedicado (los `scripts/` no
  se despliegan a runtime: manifiesto `config/runtime-deploy.v1.json`).
- El controlador despacha una vez y despues solo lee el recibo; nunca
  espera otro turno mediado por el gateway mientras esta caido.

## 1. Preflight (solo lectura) `[authorization_ref]`

Registrar cada dato en la plantilla de evidencia; un `unknown` detiene
solo su compuerta, pero estas condiciones paran antes de mutar: falta la
referencia, SHA distinto, sleep AC distinto de cero, sesion no durable,
UAC interactivo, o disco insuficiente. No cambiar energia, no reiniciar,
no cerrar sesion.

```
git --version; gh --version                      # ayuda exacta de cada CLI usada
powershell -NoProfile -Command '$PSVersionTable.PSValue'
~/.openclaw/bin/openclaw --version               # o la ruta instalada; exigir 2026.9.5
powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE   # AC: 0
query user                                       # usuario/sesion durables
wmic logicaldisk get caption,freespace,size      # backup+restore+snapshots+modelo
schtasks /query /tn "OpenClaw Gateway" /fo LIST /v
schtasks /query /tn "OpenClaw Gateway Watchdog" /fo LIST /v
schtasks /query /tn "GoncloudRepoSync" /fo LIST /v
curl.exe -s http://127.0.0.1:18789/startupz; curl.exe -s http://127.0.0.1:18789/readyz
(Get-Culture).Name                               # schtasks /sd espera en-US
```

## 2. Bootstrap confiable del checkout fuente `[authorization_ref]`

Clonar/traer DIRECTO al nuevo `C:\Users\ehven\src\goncloud-openclaw`, sin
tocar ni habilitar el sync viejo y sin correr el checkout rancio vivo:

```
git clone https://github.com/gon0801/goncloud-openclaw.git C:\Users\ehven\src\goncloud-openclaw
git -C C:\Users\ehven\src\goncloud-openclaw remote -v        # origen esperado
git -C C:\Users\ehven\src\goncloud-openclaw fetch origin
git -C C:\Users\ehven\src\goncloud-openclaw checkout --detach <merge-SHA>
git -C C:\Users\ehven\src\goncloud-openclaw rev-parse HEAD   # == <merge-SHA>
git -C C:\Users\ehven\src\goncloud-openclaw status --porcelain  # vacio
```

Verificar hashes de los artefactos que van a correr
(`RuntimeSeparation.psm1`, los seis scripts, schemas, manifiesto) contra
los registrados en la evidencia del PR. Desviacion = parar.

## 3. Respaldo de tareas y primera transaccion: backup `[authorization_ref]`

Exportar el XML de cada tarea que la operacion toque (gateway, watchdog,
nodo, CUA, `GoncloudRepoSync`, y luego las dos del cutover). El rollback
restaura XML + `.git` (seccion 11).

```
schtasks /query /tn "OpenClaw Gateway" /xml > <respaldo>\OpenClaw Gateway.xml
```

El backup real corre DENTRO de una transaccion separada (seccion 5), como
payload: el gateway se detiene, se crea/verifica el backup, se restaura a
staging fresco con ACL restringida y se inspecciona su manifiesto, y el
`finally` rearranca/verifica el gateway. Payload = wrapper `.ps1` sin
argumentos y con `exit` explicito, por ejemplo:

```powershell
# C:\Users\ehven\src\goncloud-openclaw\scripts\payload-respaldo.ps1 (ejemplo)
& "$PSScriptRoot\runtime-separation\Backup-OpenClawRuntime.ps1" `
  -RuntimeRoot 'C:\Users\ehven\.openclaw' -RepoRoot 'C:\Users\ehven\src\goncloud-openclaw' `
  -BackupDir 'C:\Users\ehven\.openclaw-backup\<fecha>' -StagingRoot 'C:\Users\ehven\.openclaw-staging' `
  -EvidencePath 'C:\Users\ehven\.openclaw-backup\<fecha>\evidencia.md' `
  -ReceiptRoot 'C:\Users\ehven\.openclaw-backup\<fecha>\recibos' `
  -LauncherPaths '<launcher-1>;<launcher-2>' `
  -HealthUrl 'http://127.0.0.1:18789' -OpenClawVersion '2026.9.5' -Apply
exit $LASTEXITCODE
```

Despachar (una vez) y luego leer el recibo en la ruta impresa:

```powershell
powershell -NoProfile -File 'C:\Users\ehven\src\goncloud-openclaw\scripts\runtime-separation\Invoke-OpenClawCutover.ps1' `
  -Dispatch -PayloadScript 'C:\Users\ehven\src\goncloud-openclaw\scripts\payload-respaldo.ps1' `
  -HealthUrl 'http://127.0.0.1:18789' -OpenClawVersion '2026.9.5' -SourceSha '<merge-SHA>'
# imprime generation=... receipt=... state=...
```

Exito = `terminal=DONE` en el log, estado `DONE`, recibo `passed` con
salud 200/200. Cualquier otro terminal se atiende por la seccion 11
antes de seguir; jamas se opera sobre un `FAILED SIN TERMINAL`.

## 4. Corte de fuente/despliegue y sync `[authorization_ref]`

Sin cambiar el checkout: exigir merge-SHA autorizado, `origin/main` y
`HEAD` del checkout dedicado IDENTICOS. Avance o desalineacion = abortar
y pedir autorizacion nueva con CI y recibos vigentes.

```
git -C C:\Users\ehven\src\goncloud-openclaw fetch origin
git -C C:\Users\ehven\src\goncloud-openclaw rev-parse HEAD origin/main
```

Desplegar staging (reporte primero, `-Apply` despues) con
`Invoke-OpenClawDeploy.ps1` y el manifiesto `config/runtime-deploy.v1.json`;
instalar el vigia v3 y leer de vuelta que el job vivo trae EXACTO el
mensaje versionado `docs/cron-messages/verif-sync-repos.v3.txt` (v3:
`SKILLS_PR` pendiente una vez, `SKILLS_DEPLOYED` salda al mergear;
salud solo del ultimo ciclo completo; se preservan `FALLO`,
`CONFLICTO` y el marcador final; el vigia es solo-lectura).

Cambiar la accion de `GoncloudRepoSync` al checkout dedicado (sobre el
XML exportado en §3, cambiando SOLO la accion; jamas habilitarla con
la accion vieja: reactivaria el sync dentro de `.openclaw`), releer el
XML vivo y verificar que apunta al checkout dedicado, y RECIEN
ENTONCES habilitar y correr:

```
schtasks /change /tn "GoncloudRepoSync" /tr "<accion-nueva-hacia-C:\Users\ehven\src\goncloud-openclaw>"
schtasks /query /tn "GoncloudRepoSync" /xml   # accion == checkout dedicado
schtasks /change /tn "GoncloudRepoSync" /enable
schtasks /run /tn "GoncloudRepoSync"
```

Exigir: cuatro resultados de repo, marcador final, exit 0, fuente
exactamente en el `origin/main` limpio autorizado, y un SEGUNDO ciclo
sin cambios (sin escrituras ni PRs nuevos). El `.git` vivo sigue en su
lugar en este punto; se mueve en §5.

## 5. Mover el `.git` vivo a cuarentena `[authorization_ref]`

Solo DESPUES de que la tarea nueva apunta al checkout limpio dedicado y
el segundo ciclo salio sin cambios. Destino fuera de las raices de
despliegue, con ACL restringida (SYSTEM + Administrators); el script
hashea e inventaria ANTES de mover y rechaza bases, WAL/SHM,
credenciales, sesiones, launchers activos, evidencia, handles abiertos y
worktrees sin cerrar. No existe borrado: lo movido se restaura por
ruta/hash registrados.

```powershell
powershell -NoProfile -File '...\scripts\runtime-separation\Move-OpenClawQuarantine.ps1' `
  -CandidatePaths 'C:\Users\ehven\.openclaw\.git' `
  -QuarantineRoot 'C:\Users\ehven\.openclaw-quarantine' `
  -RepoRoot 'C:\Users\ehven\src\goncloud-openclaw' -RuntimeRoot 'C:\Users\ehven\.openclaw' `
  -ReceiptRoot '...\recibos' -InventoryPath '...\inventario.jsonl' -Apply
```

Rollback restaura el XML de la tarea Y el `.git` a su lugar.

Verificar tras mover: runtime SIN el `.git` principal
(`Test-Path C:\Users\ehven\.openclaw\.git` = falso) y recibo `passed`
del script con el inventario registrado.

## 6. Ollama y memoria semantica `[authorization_ref]`

Verificar firma, hash, bind loopback y `/api/embed` del Ollama instalado
contra `config/ollama-runtime.v1.json`; traer `nomic-embed-text` y exigir
un embedding no vacio. Por agente: snapshot, cambiar SOLO campos de
busqueda de memoria, validar/leer de vuelta, reconstruir el indice
(obligatorio: proveedor/modelo nuevo = identidad de indice nueva),
correr una consulta semantica no literal. Probar que no hay eventos
`llama-server` 3033/3077 nuevos. Degradacion intencional: `provider: none`
da lexico puro.

```powershell
powershell -NoProfile -File '...\scripts\runtime-separation\Set-OpenClawMemory.ps1' `
  -RuntimeRoot 'C:\Users\ehven\.openclaw' -PolicyPath '...\config\ollama-runtime.v1.json' `
  -ReceiptRoot '...\recibos' -SnapshotRepo '...\snapshots' -VerifyQuery '<no literal>'
```

Rollback: `-Mode rollback` con `-MigrationPath` al recibo de migracion.

## 7. Nodo aislado `[authorization_ref]`

El script exige estado FRESCO: no emparejar a mano antes (un pairing
manual previo deja estado que el script rechaza). El script crea el
estado aislado, aplica y relee la allowlist exacta de ocho comandos
(sin wildcards/shells) sobre la identidad del dispositivo, y SOLO
entonces empareja una vez con el codigo dado (el codigo no se
persiste), instala sin `--pair` sobre el mismo estado, exporta y
elimina el duplicado `OpenClaw CUA Node`, reinicia la tarea oficial y
exige conexion y version `2026.9.5` tras salida terminal:

```powershell
powershell -NoProfile -File '...\scripts\runtime-separation\Set-OpenClawNode.ps1' `
  -NodeStateDir 'C:\Users\ehven\.openclaw-node' -NodeDisplayName '<nombre>' `
  -GatewayHost '127.0.0.1' -ApprovalsPath '...\approvals.json' `
  -NodeConfigSets '<path1>=<json1>;<path2>=<json2>' -PairingCode '<codigo-del-gateway>' `
  -ReceiptRoot '...\recibos' -Apply
```

## 8. Soak de quince minutos `[authorization_ref]`

Con trafico normal del gateway, muestrear `/readyz` y la conexion del
nodo cada 60 s durante 15 min. Un solo rojo = parar y atender (seccion
11); solo con soak verde se toca cuarentena.

## 9. Cuarentena y ensayo de reversa `[authorization_ref]`

Mover unicamente elegibles verificados (hashes destino iguales a los
registrados) y restaurar UN candidato inocuo como ensayo de reversa.
Cero borrados permanentes en toda la operacion.

## 10. Recibos redaccionados y cierre `[authorization_ref]`

Cada transicion deja recibo `runtime-separation-receipt.v1` (resultado,
salud, comandos con exits, entradas por hash, observaciones, rollback) y
log durable; ambos redaccionan formas de secreto (`[REDACTED]`), sin
credenciales, valores `.env`, material de pairing ni contenido de
memoria. Al cierre se commitea SOLO evidencia redactada y estados
terminales del ledger, en un PR de cierre, sobre la plantilla
`docs/evidence/openclaw-runtime-cutover-template.md` instanciada como
`docs/evidence/openclaw-runtime-cutover-<fecha>.md`.

Aceptacion final = CI vigente + recibos validos + sync sano de dos
ciclos + busqueda semantica + nodo aislado conectado + soak +
cero eventos Code Integrity nuevos + cero borrados permanentes.

## 11. Rollback por componente `[authorization_ref]`

- Transaccion: `terminal=ROLLED_BACK` deja servicio sano (gateway 200/200
  + watchdog habilitado); `FAILED SIN TERMINAL` deja estado no terminal
  para el dead-man o el humano. Nunca se sobrescribe un terminal; ante
  `DONE` el dead-man sale sin mutar.
- Tareas: restaurar el XML exportado (`schtasks /create /tn ... /xml ... /f`).
- `.git` vivo: `Move-OpenClawQuarantine.ps1 -Mode restore -RestoreOnly <ruta>`.
- Deploy: el recibo `rolled_back` lista lo revertido (respaldo en staging).
- Memoria: `Set-OpenClawMemory.ps1 -Mode rollback`.
- Sync/watcher: deshabilitar `GoncloudRepoSync`, restaurar mensaje previo
  del vigia, re-verificar read-back.
- Regla: un rollback tambien deja recibo; jamas se opera sobre un
  componente cuyo ultimo recibo no sea terminal y verde.

## 12. Referencia de la transaccion separada

Script: `scripts/runtime-separation/Invoke-OpenClawCutover.ps1` (5.1).
Modos excluyentes: `-Dispatch` (crea lease + estado + one-shot
`OpenClaw Cutover` + dead-man `OpenClaw Cutover DeadMan` por ruta
absoluta, arranca el one-shot, imprime `generation/receipt/state`),
`-Run` (`stop -> payload -> restart -> finalize`, reanudable, timeouts
duros por fase y globales, `try/finally`, `DONE` atomico y durable,
cancela el dead-man), `-DeadMan` (bloquea y relee justo antes de
recuperar; ante `DONE` sale sin mutar; si no, recupera y escribe
`ROLLED_BACK` solo para la misma generacion no terminal).
Estado: `C:\Users\ehven\.openclaw-cutover\{lease,state}.json` (esquemas
`cutover-lease/state.v1`), recibo determinista
`receipts\cutover-<gen>.json`, log `logs\cutover-<gen>.log`.
El watchdog y el reinicio manual se apartan/niegan ante lease vigente
(stand-down); el dead-man espera al run vivo (latido), termina al
colgado (`/end` al one-shot) y falla cerrado con lock ocupado.
Defaults: lease 120 min, dead-man 90 min, fase 600 s, global 3600 s,
sonda 10 s, recuperacion 600 s, espera 3600 s, rancio 120 s, lock 30 s.
Contrato del payload: `.ps1` absoluto, sin argumentos (wrapper),
`exit` explicito; su hash se fija en dispatch y se re-verifica en run.
