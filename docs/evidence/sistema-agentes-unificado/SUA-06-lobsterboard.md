# SUA-06, M-26: el ensayo de LobsterBoard original


Upstream github.com/Curbob/LobsterBoard, commit 7e47255371384a85706ea180f5e359495abe8b30 (Release v0.8.6, 2026-05-07), 975 estrellas.
Licencia: Business Source License 1.1 (Licensor Rich Curry); "Additional Use Grant: ... internal company use (not offered as a commercial product or service)"; Change Date 2030-02-15 a MIT. El uso interno de David entra en el permiso; vender o hospedar como servicio, no.
Instalación: clon en carpeta aislada del scratch, `npm install --omit=dev --ignore-scripts` (1 dependencia: systeminformation), `HOST=127.0.0.1 PORT=8095 node server.cjs` en la Mac. Sin contraseña por omisión ("Password auth: DISABLED").

Lo que muestra de claw:
- LobsterBoard lee OpenClaw del disco del equipo donde corre (server/routes/system.cjs): `~/.openclaw/cron/jobs.json`, `~/.openclaw/logs/gateway.log`, `~/.openclaw/openclaw.json` y `~/.openclaw/agents/main/agent/auth-profiles.json` (de este solo el tipo del perfil de anthropic), y `openclaw --version`.
- En la Mini (gateway OpenClaw 2026.9.7, `ls` de solo lectura): NO EXISTEN `cron/jobs.json` (los crons viven en SQLite), `logs/gateway.log` ni `agents/main/agent/auth-profiles.json`. Solo existe `openclaw.json`. Aun instalado en la Mini, los widgets de OpenClaw saldrían vacíos.
- El propio upstream lo dice: WIDGETS-STATUS.md:36 "OpenClaw doesn't expose REST API endpoints. These widgets require a custom backend bridge". El único widget verificado para mostrar algo propio es `iframe-embed`.
- Ensayo con la plantilla `full-screen-focus-on-openclaw-systems`: Cron "No cron jobs found" (0), System Log 0 events, Auth Type "—", Today "No activity yet today"; sí funcionan reloj, sistema/disco/red de la Mac y la versión de OpenClaw publicada en GitHub. Capturas en [SUA-06-lobsterboard/](SUA-06-lobsterboard/): `escritorio.png` y `celular.png` (vacío), `openclaw-escritorio.png` y `openclaw-celular.png` (plantilla de OpenClaw).
- Celular (390x844): el lienzo es de tamaño fijo, no se adapta; los widgets y el botón "Edit Layout" salen cortados a la derecha. No hay vista móvil.
- Red: los widgets de clima, bolsa, citas, GitHub y la versión salen a internet (terceros) desde el servidor.
- Seguridad (para el paso 4): sin contraseña, los POST (por ejemplo /api/templates/import) no piden autenticación; el `id` de plantilla entra a path.join sin normalizar (posible lectura de un config.json fuera de templates/); el error de /api/auth devuelve la ruta del archivo.

Conclusión: LobsterBoard original no muestra datos de claw (rutas de disco que OpenClaw 2026.9.x ya no usa, sin API REST), no sirve en el celular, y para mostrar nuestro estado habría que escribir la página nosotros: LobsterBoard solo la enmarcaría con su `iframe-embed`. Es el caso del paso 5 del plan: "Hacer sólo ajustes ligados a faltantes. Si requiere reescritura amplia, detener la entrega UI con evidencia y alternativas; no sustituirla automáticamente." Las alternativas (A a D) están en el §8 del [diseño](../../superpowers/specs/2026-10-16-sua-06-seguimiento-y-panel-design.md).

Decisión: David eligió el 2026-10-16 una página de solo lectura en el plugin `tablero-runbook` del gateway (diseño de SUA-06, §8). LobsterBoard no se adopta ni se instala.
