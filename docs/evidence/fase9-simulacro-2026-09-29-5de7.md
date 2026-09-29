# Evidencia — simulacro 9.9 (2026-09-29, pasada anterior sim9-20260929-0229: 5 de 7; la de 7 de 7 es fase9-simulacro-2026-09-29.md)

Corrida de esta pasada: `sim9-20260929-0229`. Los 7 casos corren de verdad. Los casos 4 y 7 se miden con reloj inyectado; con `--observar-avance` se suben a "observado real" (disparo real de avance-tareas), ver seccion "Observacion extendida".

## Version

SHA de origin/main: `5c57c7d8ac859f953166e74e8f453365eaa27b74`

## Prerrequisitos

Todos pasaron (si no, el arnes hubiera salido NO APTO antes de este punto).

## `instalar-mac.sh --verificar`

```
verificado: instalacion sana contra /Users/dn/dev/wt/canary-e4-deploy/scripts/mac
```

## Instalado (blob en origin/main vs blob instalado)

| archivo | blob en origin/main | blob instalado | igual |
|---|---|---|---|
| corrida.sh | 89c98a90283371985c950313786850be56df5f9f | 89c98a90283371985c950313786850be56df5f9f | si |
| cli-modos.tsv | a00017c159e469b2f714be99d48814d5a1c63aeb | a00017c159e469b2f714be99d48814d5a1c63aeb | si |
| workers.v1.json | 6b34582bfc0fb7927a3822144890ff5d902d7b9e | 6b34582bfc0fb7927a3822144890ff5d902d7b9e | si |
| agent-tmux.sh | d4e0bdbadd81560083fa8f0e94a4df730384ddd6 | d4e0bdbadd81560083fa8f0e94a4df730384ddd6 | si |
| agent-tmux-shell.zsh | 9e085ac53942cbccde2a4e95e3e10ff107529eda | 9e085ac53942cbccde2a4e95e3e10ff107529eda | si |
| tmux-activity-watch.sh | 727fc601b7a41099b573b13b30b014ba0541c903 | 727fc601b7a41099b573b13b30b014ba0541c903 | si |
| claude-stop-openclaw-event.sh | 745d894702fc97e3f83491fd2e80575b4bc40a51 | 745d894702fc97e3f83491fd2e80575b4bc40a51 | si |
| shot.sh | 9d316d2aac1d026bc01d8d454a23b4e502d29167 | 9d316d2aac1d026bc01d8d454a23b4e502d29167 | si |
| corrida/abrir.sh | b8afeb20cab20010279bfcff02624cedb2f9aa1c | b8afeb20cab20010279bfcff02624cedb2f9aa1c | si |
| corrida/adaptador.sh | 3778e94a8d2d8877655ba2a2edb6fd59923ab2d8 | 3778e94a8d2d8877655ba2a2edb6fd59923ab2d8 | si |
| corrida/autoridad-merge.sh | 8e30cf442a88641ab92c9d5cf685ab9d9073d5d3 | 8e30cf442a88641ab92c9d5cf685ab9d9073d5d3 | si |
| corrida/cerrar.sh | 21dc00416673b24fff907e96eb89b40cbea89a41 | 21dc00416673b24fff907e96eb89b40cbea89a41 | si |
| corrida/compuerta.sh | df20d2d430c013cfba48b2eaedda2e734a51b720 | df20d2d430c013cfba48b2eaedda2e734a51b720 | si |
| corrida/estado.sh | 18e7cef4b47f2937deabbf090d24d6246f8340b9 | 18e7cef4b47f2937deabbf090d24d6246f8340b9 | si |
| corrida/lanzar-sesion.sh | 3b767397df3843ff5b18d726d985c12e13b48fc4 | 3b767397df3843ff5b18d726d985c12e13b48fc4 | si |
| corrida/latido.sh | 83d06ff122b633ff619282b00b48f5a90c4c98be | 83d06ff122b633ff619282b00b48f5a90c4c98be | si |
| corrida/lib.sh | 6516527ab716f6954d1c927f41220536b0f0ae9e | 6516527ab716f6954d1c927f41220536b0f0ae9e | si |
| corrida/migrar-seguimiento.sh | 4e7b80741a08992639ef14d390d4d38a0561c60e | 4e7b80741a08992639ef14d390d4d38a0561c60e | si |
| corrida/mostrar-terminal.sh | ea4e4eab9486324d073c83a714a0294f3a98d1e6 | ea4e4eab9486324d073c83a714a0294f3a98d1e6 | si |
| corrida/preflight.sh | 23d0859df24ab7b683e1016d05eb2d07b817de10 | 23d0859df24ab7b683e1016d05eb2d07b817de10 | si |
| corrida/preparar-carril.sh | 97d8003c4ff827a0e61a4c9ad81ff4e0a6f7a880 | 97d8003c4ff827a0e61a4c9ad81ff4e0a6f7a880 | si |
| corrida/reconciliar-marcas.sh | 0fcb517fe8a0bfcc59ef7769071815183a72e3ab | 0fcb517fe8a0bfcc59ef7769071815183a72e3ab | si |
| corrida/reconciliar.sh | 078fe589d2be027bdb2efeb219f38559ba60a958 | 078fe589d2be027bdb2efeb219f38559ba60a958 | si |
| corrida/responder.sh | 5e6ca7db76b0cd3469036af6e2890d1c9e90119c | 5e6ca7db76b0cd3469036af6e2890d1c9e90119c | si |
| corrida/seguimiento.sh | 6ead5572cfc4bc06af556bcbe284147d4a53062f | 6ead5572cfc4bc06af556bcbe284147d4a53062f | si |
| corrida/terminar-sesion.sh | 70cde7ee2dd758ecf382b3cc5544aaff690d5e76 | 70cde7ee2dd758ecf382b3cc5544aaff690d5e76 | si |

## `runbook.progress.set` de arranque

ok

## Los 7 casos

| caso | como se provoco | hora del evento | hora del mensaje | id del mensaje | observable | resultado | que se simulo |
|---|---|---|---|---|---|---|---|
| 1 | contrato LISTO 0000000 y recoger | 2026-09-29T09:29:40Z | no aplica: sin mensaje por diseno | no aplica: sin mensaje por diseno | corrida.sh estado: 'listo (contrato: LISTO 0000000)' y 'aun no se recoge'; linea AVANZA en eventos-seguimiento.jsonl: (eventos-seguimiento.jsonl vacio todavia) | FUNCIONA | lanzar-sesion carril glm <trabajo/c1> --encargo 'responde solo la linea LISTO 0000000'; corrida.sh estado cada 5s |
| 2 | dialogo de confianza aceptado por politica | 2026-09-29T09:29:42Z | no aplica: sin mensaje por diseno | no aplica: sin mensaje por diseno | decisiones.jsonl {clase:confianza, decision:acepta}; /Users/dn/Library/Logs/tmux-activity-watch.log trae 'dialog answered by policy: sim9-t2'; pantalla de sim9-t2 paso a al-aceptar.txt | FUNCIONA | sim9-t2 (sim9-tui-falso) con dialogo de confianza de carpeta + al-aceptar.txt listo |
| 3 | comando que escala y NECESITA TU RESPUESTA | 2026-09-29T09:29:43Z | 2026-09-29T09:30:06Z | 7781 | decisiones.jsonl {clase:comando, decision:escala, enviado:true}; mensajes.jsonl NECESITO TU RESPUESTA ok:true con message_id, texto con el contrato de seguimiento.v1 y el prefijo [SIMULACRO] (lo garantiza corrida_mensaje, commit 9.9.1) | FUNCIONA | sim9-t3 (sim9-tui-falso) con 'Run this command? $ ssh otra-maquina uptime', preaprobaciones vacias |
| 4 | reloj inyectado: 30 min sin actividad | 2026-09-29T09:30:32Z |  |  |  | NO FUNCIONA (observado real: cron avance-tareas a las 2026-09-29T09:32:08Z, scratch confirmado a las 2026-09-29T10:02:10Z (messageId 7783)) | sim9-t4 callado 30 min (reloj inyectado en corrida.sh estado); runbook.progress.decide con inmediato DETENIDA sintetico |
| 5 | kill-session de un carril y relanzamiento | 2026-09-29T09:31:11Z | no aplica: sin mensaje por diseno | no aplica: sin mensaje por diseno | eventos.jsonl del vigia: 'sim9-c5 closed'; sesion nueva sim9-c5 con OPENCLAW_WATCH_RUN=sim9-20260929-0229; registro con exactamente una entrada mas para /Users/dn/.local/state/corridas/sim9-20260929-0229/trabajo/c5/; sin segundo relanzamiento en 15s | FUNCIONA | kill-session sim9-c5 (carril, glm, marcada); se espera el relanzamiento real del vigia (corrida.sh lanzar-sesion), sin pasar por main |
| 6 | kill-session del lead y relanzamiento | 2026-09-29T09:31:21Z | no aplica: sin mensaje por diseno | no aplica: sin mensaje por diseno | eventos.jsonl del vigia: 'sim9-lead closed'; sesion nueva sim9-lead con OPENCLAW_WATCH_RUN=sim9-20260929-0229; registro con exactamente una entrada mas para /Users/dn/.local/state/corridas/sim9-20260929-0229/trabajo/c6/; sin segundo relanzamiento en 15s | FUNCIONA | kill-session sim9-lead (lead, glm, marcada); se espera el relanzamiento real del vigia (corrida.sh lanzar-sesion), sin pasar por main |
| 7 | corte de 30 min con reporte-confirmado | 2026-09-29T09:31:29Z |  |  |  | NO FUNCIONA (observado real: cron avance-tareas a las 2026-09-29T09:32:08Z, scratch confirmado a las 2026-09-29T10:02:10Z (messageId 7783)) | runbook.progress.decide modo:tick, estado sintetico {corte:{kind:reporte-confirmado, ultimoReporteConfirmado: ahora-3600}} (control negativo: ahora-1400, bajo la ventana de 1500 del R12); con seguimiento.v2 el latido de 60 min lo cubre el corte de 30 |

## Lo no observado

Ver el detalle del caso 4 y 7 arriba, y la seccion "Observacion extendida" de abajo.

Un caso en NO FUNCIONA queda con su detalle en la fila de arriba, no aqui.

## Observacion extendida

pedida (--observar-avance 50); turno mandado a las 2026-09-29T09:31:30Z; (a) cron avance-tareas visto a las 2026-09-29T09:32:08Z; (b) scratch reporte-confirmado a las 2026-09-29T10:02:10Z con messageId 7783; casos 4 y 7: FUNCIONA observado real; al cerrar, el cron avance-tareas: no se vio retirado en 120s tras el cierre (dato, no bloqueante)

## Eventos del vigia filtrados por `sim9-`

```
{"t":1790315539,"evento":"tmux: sim9-t3 waiting for approval for 0s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260924-2251/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790315589,"evento":"tmux: sim9-c5 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260924-2251/trabajo/c5"}
{"t":1790315591,"evento":"tmux: sim9-lead closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260924-2251/trabajo/c6"}
{"t":1790315861,"evento":"tmux: sim9-c1 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260924-2251/trabajo/c1"}
{"t":1790315863,"evento":"tmux: sim9-t2 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260924-2251/trabajo/c2"}
{"t":1790315865,"evento":"tmux: sim9-t3 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260924-2251/trabajo/c3"}
{"t":1790315867,"evento":"tmux: sim9-t4 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260924-2251/trabajo/c4"}
{"t":1790321655,"evento":"tmux: sim9-t3 waiting for approval for 0s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0033/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790321706,"evento":"tmux: sim9-c5 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-0033/trabajo/c5"}
{"t":1790321708,"evento":"tmux: sim9-lead closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-0033/trabajo/c6"}
{"t":1790322552,"evento":"tmux: sim9-c1 quiet for 908s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-0033/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790322587,"evento":"tmux: sim9-t2 quiet for 914s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0033/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790322590,"evento":"tmux: sim9-t3 quiet for 914s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0033/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790322592,"evento":"tmux: sim9-t4 quiet for 914s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0033/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790323453,"evento":"tmux: sim9-c1 quiet for 1808s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-0033/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790323488,"evento":"tmux: sim9-t2 quiet for 1815s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0033/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790323491,"evento":"tmux: sim9-t3 quiet for 1815s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0033/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790323493,"evento":"tmux: sim9-t4 quiet for 1815s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0033/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790324082,"evento":"tmux: sim9-c1 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-0033/trabajo/c1"}
{"t":1790324085,"evento":"tmux: sim9-t2 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-0033/trabajo/c2"}
{"t":1790324087,"evento":"tmux: sim9-t3 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-0033/trabajo/c3"}
{"t":1790324090,"evento":"tmux: sim9-t4 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-0033/trabajo/c4"}
{"t":1790325714,"evento":"tmux: sim9-t3 waiting for approval for 0s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0141/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790325765,"evento":"tmux: sim9-c5 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-0141/trabajo/c5"}
{"t":1790325767,"evento":"tmux: sim9-lead closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-0141/trabajo/c6"}
{"t":1790326596,"evento":"tmux: sim9-c1 quiet for 908s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-0141/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790326646,"evento":"tmux: sim9-t2 quiet for 913s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0141/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790326648,"evento":"tmux: sim9-t3 quiet for 913s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0141/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790326651,"evento":"tmux: sim9-t4 quiet for 914s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0141/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790327497,"evento":"tmux: sim9-c1 quiet for 1808s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-0141/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790327547,"evento":"tmux: sim9-t2 quiet for 1814s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0141/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790327550,"evento":"tmux: sim9-t3 quiet for 1814s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0141/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790327553,"evento":"tmux: sim9-t4 quiet for 1815s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0141/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790328340,"evento":"tmux: sim9-t3 waiting for approval for 0s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0225/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790328390,"evento":"tmux: sim9-c5 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-0225/trabajo/c5"}
{"t":1790328393,"evento":"tmux: sim9-lead closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-0225/trabajo/c6"}
{"t":1790329232,"evento":"tmux: sim9-c1 quiet for 909s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-0225/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790329268,"evento":"tmux: sim9-t2 quiet for 909s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0225/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790329271,"evento":"tmux: sim9-t3 quiet for 909s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0225/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790329273,"evento":"tmux: sim9-t4 quiet for 909s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0225/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790329485,"evento":"tmux: sim9-c5 quiet for 910s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-0225/trabajo/c5 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c5 -S -80"}
{"t":1790329488,"evento":"tmux: sim9-lead quiet for 909s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-0225/trabajo/c6 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-lead -S -80"}
{"t":1790330137,"evento":"tmux: sim9-c1 quiet for 1814s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-0225/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790330172,"evento":"tmux: sim9-t2 quiet for 1813s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0225/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790330175,"evento":"tmux: sim9-t3 quiet for 1813s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0225/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790330178,"evento":"tmux: sim9-t4 quiet for 1813s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0225/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790330389,"evento":"tmux: sim9-c5 quiet for 1815s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-0225/trabajo/c5 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c5 -S -80"}
{"t":1790330392,"evento":"tmux: sim9-lead quiet for 1814s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-0225/trabajo/c6 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-lead -S -80"}
{"t":1790334009,"evento":"tmux: sim9-t3 waiting for approval for 0s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0359/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790334075,"evento":"tmux: sim9-c5 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-0359/trabajo/c5"}
{"t":1790334079,"evento":"tmux: sim9-lead closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-0359/trabajo/c6"}
{"t":1790334897,"evento":"tmux: sim9-c1 quiet for 901s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-0359/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790334932,"evento":"tmux: sim9-t3 quiet for 905s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0359/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790334951,"evento":"tmux: sim9-t2 quiet for 906s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0359/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790334954,"evento":"tmux: sim9-t4 quiet for 907s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0359/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790335072,"evento":"tmux: sim9-c5 quiet for 905s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-0359/trabajo/c5 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c5 -S -80"}
{"t":1790335808,"evento":"tmux: sim9-c1 quiet for 1813s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-0359/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790335843,"evento":"tmux: sim9-t3 quiet for 1816s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0359/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790335861,"evento":"tmux: sim9-t2 quiet for 1817s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0359/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790335864,"evento":"tmux: sim9-t4 quiet for 1818s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0359/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790335982,"evento":"tmux: sim9-c5 quiet for 1815s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-0359/trabajo/c5 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c5 -S -80"}
{"t":1790336718,"evento":"tmux: sim9-c1 quiet for 2723s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-0359/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790336753,"evento":"tmux: sim9-t3 quiet for 2725s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0359/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790336772,"evento":"tmux: sim9-t2 quiet for 2727s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0359/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790336775,"evento":"tmux: sim9-t4 quiet for 2728s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-0359/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790355638,"evento":"tmux: sim9-t3 waiting for approval for 0s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1000/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790355689,"evento":"tmux: sim9-c5 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-1000/trabajo/c5"}
{"t":1790355692,"evento":"tmux: sim9-lead closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-1000/trabajo/c6"}
{"t":1790356534,"evento":"tmux: sim9-c1 quiet for 913s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-1000/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790356570,"evento":"tmux: sim9-t2 quiet for 913s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1000/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790356573,"evento":"tmux: sim9-t3 quiet for 913s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1000/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790356577,"evento":"tmux: sim9-t4 quiet for 913s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1000/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790357022,"evento":"tmux: sim9-c5 quiet for 911s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-1000/trabajo/c5 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c5 -S -80"}
{"t":1790357025,"evento":"tmux: sim9-lead quiet for 910s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-1000/trabajo/c6 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-lead -S -80"}
{"t":1790357433,"evento":"tmux: sim9-c1 quiet for 1813s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-1000/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790357484,"evento":"tmux: sim9-t2 quiet for 1828s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1000/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790357487,"evento":"tmux: sim9-t3 quiet for 1828s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1000/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790357489,"evento":"tmux: sim9-t4 quiet for 1828s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1000/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790357934,"evento":"tmux: sim9-c5 quiet for 1823s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-1000/trabajo/c5 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c5 -S -80"}
{"t":1790357937,"evento":"tmux: sim9-lead quiet for 1822s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-1000/trabajo/c6 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-lead -S -80"}
{"t":1790358343,"evento":"tmux: sim9-c1 quiet for 2723s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-1000/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790358395,"evento":"tmux: sim9-t2 quiet for 2739s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1000/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790358399,"evento":"tmux: sim9-t3 quiet for 2739s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1000/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790358402,"evento":"tmux: sim9-t4 quiet for 2739s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1000/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790360105,"evento":"tmux: sim9-t3 waiting for approval for 0s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1114/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790360157,"evento":"tmux: sim9-c5 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-1114/trabajo/c5"}
{"t":1790360159,"evento":"tmux: sim9-lead closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-1114/trabajo/c6"}
{"t":1790360991,"evento":"tmux: sim9-c1 quiet for 914s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-1114/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790361025,"evento":"tmux: sim9-t2 quiet for 901s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1114/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790361028,"evento":"tmux: sim9-t3 quiet for 901s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1114/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790361031,"evento":"tmux: sim9-t4 quiet for 902s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1114/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790361049,"evento":"tmux: sim9-c1 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-1114/trabajo/c1"}
{"t":1790361051,"evento":"tmux: sim9-t2 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-1114/trabajo/c2"}
{"t":1790361054,"evento":"tmux: sim9-t3 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-1114/trabajo/c3"}
{"t":1790361056,"evento":"tmux: sim9-t4 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-1114/trabajo/c4"}
{"t":1790364465,"evento":"tmux: sim9-t3 waiting for approval for 0s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1227/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790364642,"evento":"tmux: sim9-c5 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-1227/trabajo/c5"}
{"t":1790364645,"evento":"tmux: sim9-lead closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-1227/trabajo/c6"}
{"t":1790365379,"evento":"tmux: sim9-c1 quiet for 915s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-1227/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790365398,"evento":"tmux: sim9-t2 quiet for 914s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1227/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790365513,"evento":"tmux: sim9-t3 quiet for 902s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1227/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790365516,"evento":"tmux: sim9-t4 quiet for 903s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1227/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790365534,"evento":"tmux: sim9-c1 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-1227/trabajo/c1"}
{"t":1790365537,"evento":"tmux: sim9-t2 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-1227/trabajo/c2"}
{"t":1790365539,"evento":"tmux: sim9-t3 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-1227/trabajo/c3"}
{"t":1790365542,"evento":"tmux: sim9-t4 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-1227/trabajo/c4"}
{"t":1790370003,"evento":"tmux: sim9-t3 waiting for approval for 0s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1359/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790370053,"evento":"tmux: sim9-c5 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-1359/trabajo/c5"}
{"t":1790370056,"evento":"tmux: sim9-lead closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260925-1359/trabajo/c6"}
{"t":1790370896,"evento":"tmux: sim9-c1 quiet for 911s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-1359/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790370931,"evento":"tmux: sim9-t2 quiet for 910s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1359/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790370933,"evento":"tmux: sim9-t3 quiet for 910s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1359/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790370936,"evento":"tmux: sim9-t4 quiet for 910s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1359/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790371809,"evento":"tmux: sim9-c1 quiet for 1825s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-1359/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790371843,"evento":"tmux: sim9-t2 quiet for 1822s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1359/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790371847,"evento":"tmux: sim9-t3 quiet for 1822s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1359/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790371849,"evento":"tmux: sim9-t4 quiet for 1822s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1359/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790372719,"evento":"tmux: sim9-c1 quiet for 2735s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260925-1359/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790372753,"evento":"tmux: sim9-t2 quiet for 2732s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1359/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790372756,"evento":"tmux: sim9-t3 quiet for 2732s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1359/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790372759,"evento":"tmux: sim9-t4 quiet for 2732s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260925-1359/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790653220,"evento":"tmux: sim9-t3 waiting for approval for 0s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790653277,"evento":"tmux: sim9-c5 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c5"}
{"t":1790653284,"evento":"tmux: sim9-lead closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c6"}
{"t":1790654105,"evento":"tmux: sim9-c1 quiet for 900s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790654151,"evento":"tmux: sim9-t2 quiet for 901s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790654158,"evento":"tmux: sim9-t3 quiet for 901s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790654165,"evento":"tmux: sim9-t4 quiet for 902s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790655012,"evento":"tmux: sim9-c1 quiet for 1805s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790655059,"evento":"tmux: sim9-t2 quiet for 1808s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790655066,"evento":"tmux: sim9-t3 quiet for 1808s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790655073,"evento":"tmux: sim9-t4 quiet for 1809s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790655797,"evento":"tmux: sim9-t2 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c2"}
{"t":1790655822,"evento":"tmux: sim9-t4 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c4"}
{"t":1790655921,"evento":"tmux: sim9-c1 quiet for 2714s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790656096,"evento":"tmux: sim9-c5 quiet for 903s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c5 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c5 -S -80"}
{"t":1790656118,"evento":"tmux: sim9-lead quiet for 914s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c6 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-lead -S -80"}
{"t":1790656784,"evento":"tmux: sim9-t2 quiet for 913s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790656792,"evento":"tmux: sim9-t3 quiet for 912s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790656799,"evento":"tmux: sim9-t4 quiet for 913s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790656822,"evento":"tmux: sim9-c1 quiet for 3616s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260928-2039/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790674213,"evento":"tmux: sim9-t3 waiting for approval for 0s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260929-0229/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790674271,"evento":"tmux: sim9-c5 closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260929-0229/trabajo/c5 | relanzada automaticamente: corrida.sh lanzar-sesion sim9-20260929-0229 carril glm /Users/dn/.local/state/corridas/sim9-20260929-0229/trabajo/c5 --nombre sim9-c5"}
{"t":1790674281,"evento":"tmux: sim9-lead closed | last cwd=/Users/dn/.local/state/corridas/sim9-20260929-0229/trabajo/c6 | relanzada automaticamente: corrida.sh lanzar-sesion sim9-20260929-0229 lead glm /Users/dn/.local/state/corridas/sim9-20260929-0229/trabajo/c6 --nombre sim9-lead"}
{"t":1790675109,"evento":"tmux: sim9-c1 quiet for 908s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260929-0229/trabajo/c1 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c1 -S -80"}
{"t":1790675158,"evento":"tmux: sim9-t2 quiet for 914s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260929-0229/trabajo/c2 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t2 -S -80"}
{"t":1790675166,"evento":"tmux: sim9-t3 quiet for 914s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260929-0229/trabajo/c3 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t3 -S -80"}
{"t":1790675174,"evento":"tmux: sim9-t4 quiet for 914s | cmd=bash cwd=/Users/dn/.local/state/corridas/sim9-20260929-0229/trabajo/c4 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-t4 -S -80"}
{"t":1790675197,"evento":"tmux: sim9-c5 quiet for 925s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260929-0229/trabajo/c5 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-c5 -S -80"}
{"t":1790675205,"evento":"tmux: sim9-lead quiet for 916s | cmd=node cwd=/Users/dn/.local/state/corridas/sim9-20260929-0229/trabajo/c6 | read it before acting: /opt/homebrew/bin/tmux capture-pane -p -t sim9-lead -S -80"}
```

## Lo que quedo en disco

- `/Users/dn/.local/state/corridas/sim9-20260929-0229/registro.json`, `/Users/dn/.local/state/corridas/sim9-20260929-0229/decisiones.jsonl`, `/Users/dn/.local/state/corridas/sim9-20260929-0229/mensajes.jsonl`, `/Users/dn/.local/state/corridas/sim9-20260929-0229/eventos-seguimiento.jsonl` (la corrida se cierra antes de salir; se quedan para inspeccion).
- `/Users/dn/.local/state/corridas/sim9-20260929-0229/trabajo/c1`, `c2`, `c3` (y `c4`-`c7` cuando existan) — nunca se borran de forma recursiva.
- `/Users/dn/.local/state/corridas/sim9-20260929-0229/cli-modos.tsv` y `/Users/dn/.local/state/corridas/sim9-20260929-0229/bin/sim9-tui-falso` (la tabla generada por el arnes).

Nunca el destino del canal de mensajes.
