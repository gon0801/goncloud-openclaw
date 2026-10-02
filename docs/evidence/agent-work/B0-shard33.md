# B0 — rojos del shard 3/3 y bloqueante del veredicto r1 (recibo)

Corrección de la ronda B0-2-r1 más los dos rojos que el run `36983382776` dejó en el job
`shards (3/3)` (`test-simulacro-fase9.sh` y `test-skill-autopilot-runbook.sh`; en main `8e2dde0`
el shard está verde, run `36950733382`). Los tres arreglos, con rojo y verde reales. Los tres
tests se descubren solos por el glob `scripts/tests/*.sh` de `run-checks.sh`, por eso un repro
nuevo también corre en el shard y debía sobrevivir su checkout superficial.

## Bloqueante 1: el repro doc-check reventaba sin origin/main (exit 128)

`scripts/tests/test-doc-check-evidencia.sh` resolvía la base con `git merge-base origin/main`,
pero el job shards hace checkout superficial sin `origin/main` (`fetch --depth=1` del merge,
`quality.yml:255`): exit 128 por `set -e` en cada PR con carril completo. Mismo fallo que ya tuvo
`test-corrida-preflight.sh` (CI #153). Arreglo: opción (a) del veredicto, el patrón del paso real
(`quality.yml:133-135`): `git rev-parse --verify --quiet 'origin/main^{commit}'`; si no resuelve,
avisa y sale 0 porque el doc-check real corre en `clasificador` con `fetch-depth 0`.

Rojo, clon superficial en `04c3240` (una sola ref, sin `origin/main`, igual que shards):

```
$ bash scripts/tests/test-doc-check-evidencia.sh
fatal: Not a valid object name origin/main
```

exit=128. Verde, mismo clon en `5aa9014` (commit del arreglo):

```
$ bash scripts/tests/test-doc-check-evidencia.sh
doc-check-repro: omitido: sin origin/main (checkout superficial); el doc-check real corre en clasificador con fetch-depth 0
```

exit=0. Regresión de los caminos normales en el worktree: sin argumentos sigue auditando el rango
completo (`doc-check-repro: OK (163 archivo(s) en el rango)`, exit 0) y con `19e3ee3` como
argumento sigue saliendo rojo histórico (`RECHAZADO (161 archivo(s) en el rango)`, exit 1
nombrando los 15 de la r1). La mutación no aplica como paso aparte: el rojo previo al arreglo es
el mismo clon con el script de `04c3240`, así que el bracket rojo/verde compara exactamente el
guion con y sin la guarda.

## Bloqueante 2: test-simulacro-fase9, "instalar-mac.sh --verificar no salio 0"

Log de CI (`gh run view 36983382776 --job 110762866185 --log-failed`): la prueba cae en 0s con
`- instalar-mac.sh --verificar no salio 0`. Rojo local idéntico (árbol `04c3240`):

```
FAIL: todo sano: se esperaba salida 0 (7/7 FUNCIONA), salio 2 -- NO APTO
- instalar-mac.sh --verificar no salio 0
```

exit=1. Causa raíz: `modo_verificar` exige desde `4eaf41a` que `bin/agent-work/` sea idéntico a
`scripts/agent-work/` y que `cutover.py` tenga +x, y el HOME de mentira del simulacro nunca pobló
eso. Arreglo: el fixture deriva `AGENT_WORK_FILES` del propio instalador (mismo patrón que ya usa
con `BINS`) y reproduce el `chmod 755` de `modo_instalar`.

Mutación del contrato `--verificar` (HOME falso recién construido con la receta nueva del fixture,
en `/tmp/r2-mut-home/home`, sin tocar el worktree):

```
$ HOME=$H bash scripts/mac/instalar-mac.sh --verificar
verificado: instalacion sana contra /Users/dn/dev/wt/encargos-b0/scripts/mac
```

exit=0. Se borra `bin/agent-work/routing.py` del HOME:

```
$ HOME=$H bash scripts/mac/instalar-mac.sh --verificar
DIFIERE: bin/agent-work/routing.py
verificar: 1 problema(s) contra /Users/dn/dev/wt/encargos-b0/scripts/mac
```

exit=1, nombrando exactamente el archivo mutado. Se restaura el archivo:

```
verificado: instalacion sana contra /Users/dn/dev/wt/encargos-b0/scripts/mac
```

exit=0.

## Bloqueante 2-bis (hallazgo de la verificación): los casos 5/6 del ensayo exigían la semántica append previa a 19e3ee3

Con el `--verificar` en verde, el ensayo avanzó por primera vez con esta rama y los casos 5 y 6
(kill-session y relanzamiento del vigía) salieron NO FUNCIONA (dos corridas, la segunda con la
máquina ociosa, así que no fue carga):

```
FAIL: todo sano: se esperaba salida 0 (7/7 FUNCIONA), salio 1 -- arrancada sim9-20261002-0806
arnes 9.9: 5/7 casos FUNCIONA
| 5 | kill-session de un carril y relanzamiento | ... | NO FUNCIONA (en 30s no se vio 'closed' + sesion nueva marcada + registro con una entrada mas para .../trabajo/c5)
| 6 | kill-session del lead y relanzamiento   | ... | NO FUNCIONA (en 30s no se vio 'closed' + sesion nueva marcada + registro con una entrada mas para .../trabajo/c6)
```

Los logs del árbol conservado de la corrida prueban que el vigía SÍ relanzó en ~2s
(`eventos.jsonl`: `{"tipo": "relanzo-automatico", "sesion": "sim9-c5", "ok": true, ...}` y el
equivalente de `sim9-lead`) y que el registro quedó con UNA entrada por sesión. Lo que fallaba era
la aserción: el arnés (`scripts/mac/simulacro-fase9.sh`, `correr_relanzo_kill`) y el test
(`test-simulacro-fase9.sh` 1f, con su comentario "lanzar-sesion siempre APPEND-ea (nunca
reemplaza)") exigían que el registro ganara "una entrada mas", la semántica append previa a
`19e3ee3` (APROBADO en B0-1-r2: el relanzo del mismo nombre REEMPLAZA la entrada muerta). CI nunca
lo vio porque el `--verificar` rojo abortaba el ensayo antes de los casos. Arreglo: el arnés
exige ahora entrada reemplazada (conteo estable en `$antes`) y exactamente un evento
`relanzo-automatico` por sesión en `eventos.jsonl` (bajo reemplazo, un segundo relanzamiento ya no
se ve en el conteo del registro), y el test espera 1 entrada de `sim9-c5`, no 2.

Verde completo en el árbol final (`d1f0a22`), pasadas ~14 min por los topes del ensayo:

```
TODO VERDE: simulacro-fase9 (piezas a-e)
```

exit=0.

## Bloqueante 3: test-skill-autopilot-runbook, el primer comando de fase 17 no "abre la corrida"

Rojo local (árbol `04c3240`), idéntico al de CI:

```
FAIL: (5) docs/runbooks/autopilot-fase17.md: primer comando no abre la corrida
```

exit=1. Causa raíz, medida con el propio extractor del checker (primer bloque cercado de cada
runbook): `autopilot-fase17.md` en main contenía el literal `runbook.progress.set` (1) y el árbol
de la rama lo perdió (0) porque `855d317` + `a19501c` movieron la apertura al evento duradero
`run.opened`; los otros cuatro literales exigidos (`corrida`, `proyecto`, `plan`, `pendiente`)
siguen presentes. Los runbooks 13-16 y el fixture bueno conservan `runbook.progress.set` (1) y el
fixture malo no tiene ninguno. Arreglo: el checker acepta las dos grafías del mismo acto
(`run\.progress\.set|run\.opened`) y conserva los otros cuatro literales; no se tocó el runbook ni
los fixtures. La propia skill que este test candala ya enseña la API de eventos y prohibe instruir
`runbook.progress.set` en su slot 12, así que la dirección es la de la rama.

Verde en el árbol final (`1416dd0`):

```
ok (1): frontmatter con name y description
ok (2): los dieciseis slots de la receta están
ok (2-bis): la entrega se prueba con un comando, y la corrida nace con el runbook
ok (3): las diecinueve anclas de reglas están
ok (4): la copia de la Mac no es la de esta rama, pero es la versión de refs/heads/chore/skills-editadas-en-vivo (0891f77b16ee98199d55f58fbf968caf669df7c0)
ok (5): el primer comando de un runbook nuevo abre la corrida
TODO VERDE: skill autopilot-runbook
```

exit=0 (el fixture malo sigue rebotando: el test lo afirma dentro del propio chequeo 5).

## Alcance

- No se tocó `quality.yml`, `gate` ni `shards`; no se relajó ningún contrato: el doc-check del
  repro sigue fallando en rojo con cualquier evidencia fuera de contrato (probado contra
  `19e3ee3`), el `--verificar` sigue detectando cada pieza faltante (mutación arriba) y el checker
  de runbooks sigue exigiendo apertura con identidad completa más el fixture malo en rojo.
- Pruebas focalizadas de lo tocado, nada de batería completa. Los tres tests corren aislados
  (HOMEs falsos, sockets tmux propios, clones en `/tmp`); ningún carril vivo fue tocado.
- No es tarea del plan: sin mediciones de casilla ni build (solo shell y docs).
