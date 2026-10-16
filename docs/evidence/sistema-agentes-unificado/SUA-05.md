# SUA-05, recibo del bloque: ingeniería y calidad

Bloque SUA-05 del
[plan](../../superpowers/plans/2026-10-05-sistema-agentes-unificado.md), hecho según su
[diseño](../../superpowers/specs/2026-10-16-sua-05-ingenieria-y-calidad-design.md). Las
mediciones viven fuera del repo, en `~/.local/state/sua-loop/mediciones/` (`m25/`,
`banco-h125/`); este recibo cita sus resultados. R es el checkout de integración de
OpenClaw; su rama del bloque es `feat/agent-work-integration` en
`~/dev/openclaw-agent-work-integration` (`c7a58a6b`, respaldada; la Mini sigue en
`7b3db54226bf`). G es este repo.

## Qué entregó

- **La política de rondas quedó como datos, en G y en R con la misma tabla.**
  `docs/evidence/agent-work/politica-calidad.json` guarda `quality-kit.regla4`
  (tope 5+5, relevo 1, revisor que excluye autores, sin segundo modelo) con la
  decisión fechada de David del 2026-10-12. `contrato.py` rechaza una
  `meta.qualityPolicy.version` que no esté en el archivo (`quality-policy-unknown`),
  y una prueba exige la paridad con `ROOT_QUALITY_POLICIES` de
  `managed-root.decide.ts` en R. En R, `findingsRefs` acumula los hallazgos de
  todos los intentos fallidos de la unidad (antes solo pasaba el último).
- **El veredicto tiene forma.** `findingsRef` apunta a un `hallazgos.v1`
  (`bloqueante` con `reproduce` obligatorio); un `approved` cuya evidencia trae un
  bloqueante (tipado o una línea `BLOCKER`/`BLOQUEANTE` en texto) sale
  `aprobado-con-bloqueante`, y `progress_bridge.py` acepta los veredictos del
  contrato (`approved`/`changes`).
- **La marca de completitud del bot no miente.** En goncloud-pr-review
  (#115), un archivo excluido por tamaño baja la cobertura a `partial`, y G fija
  ese sha en sus workflows (#329).
- **El merge es un comando con compuertas, no una orden a mano.**
  `scripts/agent-work/merge.py` (H4, #330) trae `listo`, `mergear` y
  `reintentar <PR> --sha <head>`: draft y head exacto, checks verdes de ese SHA,
  CodeRabbit (un `rate limited` pasa con aviso, decisión del 2026-09-25), la
  evidencia del bot firmada por `github-actions[bot]` con su `completion` del
  head, y cada hallazgo abierto descartado o adjudicado con su forma literal; la
  receta por repo vive en `docs/evidence/agent-work/recetas-repos.json`.
- **El carril rápido dejó de colar el corpus y el duplicado de CI.** Los archivos
  que una prueba lee clasifican `completo` por lista vigilada
  (`clasificar-cambio.sh`), `test-ci-coverage-contract.sh` corre una sola vez en
  `ci-contract`, y el gate exige la unión exacta de los shards.
- **El runbook habla el idioma de la política nueva.** `loop-autopilot.md` §4
  quedó en corto: regla 4 de quality-kit con tope 5+5 y relevo, los bots y CI como
  revisores, sin cruzada, sin rotación de revisor, sin paro por bloqueante
  repetido y sin subagente propio; la ronda cierra en el PR y **solo el
  coordinador** comenta, descarta (`ai-review: descartar F<n>`) y adjudica;
  §6 manda `merge.py mergear` con sus compuertas. Las SKILLs de cierre
  (`saikit-cierre-pr` en sus dos copias, `kit-merge-route.md`, `mac-node-ops`,
  `agent-dispatch`, `git-commit-push`, `goncloud-ssh-ops`), los cuatro contratos
  de `workspace-*/AGENTS.md` y los runbooks base (`base-openclaw`,
  `base-summonaikit`, `base-orbit`, `camino-feliz-producto`) nombran el mismo
  comando, y la plantilla de briefs (`encargo-cli`, `agent-dispatch`) prohíbe al
  implementador comentar, descartar o empujar en GitHub.

## Estado por línea del "Verificar"

| Verificar | Estado | Prueba |
|---|---|---|
| Código cero con texto `BLOCKER` no aprueba | **Cumplido** (H2, #328). `approved` con `hallazgos.v1` bloqueante y con línea `BLOCKER` salen `aprobado-con-bloqueante`. | `test-agent-work-reporte.py`, `test-agent-work-host.py` |
| Evidencia de otro head falla | **Cumplido** (H4, #330). Comentario del bot con la marca de otro SHA: `evidencia-de-otro-head`. | `test-agent-work-merge.py` |
| Comentario de bot sin check-run falla | **Cumplido** (H4, #330). Los mismos marcadores escritos por otra cuenta, sin marca de completitud o con la forma legada: no listo. | `test-agent-work-merge.py` |
| Un bloqueante nuevo en cada ronda no reinicia límites | **Cumplido** (H1, #328): en R, tres rondas con hallazgos distintos dejan la lista acumulada y el contador sigue; la paridad fija las mismas versiones en los dos lados. | Prueba de `managed-root` en R (`c7a58a6b`); `test-sistema-agentes-contrato.py` (paridad con `ROOT_QUALITY_POLICIES`) |
| Activar otra política sin la decisión de David falla | **Cumplido** (H1, #328): `activa` distinta sin `decision` nueva falla, y `contrato.py` rechaza una versión que no está (`quality-policy-unknown`). | `test-sistema-agentes-contrato.py` |
| Ningún paso pide revisión a un segundo modelo | **Cumplido** (H6, esta rebanada): `segundoModelo: false` en la política y candado que veda la cruzada en los runbooks vivos (solo dentro de sus líneas `Medido:`). Ninguna SKILL administrada la nombra. | `test-loop-autopilot.sh` (bloques 3-r1 y 3f) |
| Cambiar corpus dispara su checker | **Cumplido** (H5, #328): tocar `docs/evidence/corpus-rendiciones.tsv` clasifica `completo`. | `test-clasificador-cambio.sh` |
| Shard vacío o prueba omitida hace fallar cobertura | **Cumplido** (H5, #328): la unión exacta de los shards y el inventario sin duplicado. | `test-ci-coverage-contract.sh`, `test-runner-shards.sh` |
| Reviewer sin acceso de escritura a fuente | **Cumplido y citado**: probado en SUA-03 (`revisor-con-escritura`, clon desechable) y SUA-04 G7 (banco `claude-revision-rota`). | `test_agent_work_banco_e2e.py`; recibos SUA-03 y SUA-04 |

## Las mediciones

- **M-25, qué corrida mira GitHub** (`~/.local/state/sua-loop/mediciones/m25/RESULTADO.md`).
  Re-corrida a propósito del job `clasificador` sobre el head de #329:
  `GET /commits/<sha>/check-runs` con el filtro por omisión trae una sola fila por
  nombre (la última), `filter=all` trae todas, y `statusCheckRollup` ya viene con
  la última. `merge.py` agrupa por nombre y se queda con la de `started_at` más
  reciente.
- **Banco de revisión con `hallazgos.v1`**
  (`~/.local/state/sua-loop/mediciones/banco-h125/`, verde el 2026-10-16T13:16:39Z,
  sobre H1+H2+H5): `claude` revisa el repo roto con `verdict=changes` y deja el
  repo igual (73 s); `opencode` da `changes` en el roto y `approved` en el sano
  (457 s los dos casos).
- **La ventana viva del bloque, el 2026-10-16**: #325 mergeado 12:18Z; banco
  `hallazgos.v1` verde 13:16Z; #115 mergeado 15:55Z y #329 mergeado 16:19Z (H3 en
  los dos repos); host vivo en `78ce9e70` desde 14:02Z; `feat/agent-work-integration`
  adelantada a `c7a58a6b` (16:26Z); #330 (H4) mergeado como `560497f2`; H6 en #331.

## Los PR

| PR | Merge | Qué trajo |
|---|---|---|
| #325 | `6f9ee041` | Diseño del bloque |
| #328 | `78ce9e70` | H1, H2 y H5: política de calidad, veredicto con forma, carril rápido y unión de shards |
| goncloud-pr-review #115 | `cc7edd90` | H3 en el repo del bot: el recorte por tamaño degrada la marca a `partial` |
| #329 | `7755ae54` | H3 en G: el sha del bot fijado en los workflows |
| #330 | `560497f2` | H4: `merge.py` con sus compuertas, recetas por repo y reintento |
| #331 | — | H6: runbook, SKILLs, contratos, filas y este recibo |

En R, `feat/agent-work-integration` lleva el lado de H1 (`findingsRefs` acumulados
y su prueba) hasta `c7a58a6b`, respaldada. Implementó GLM 5.3 Flash (H125, H3-pin,
H4 y H6). Diseñó y revisó el coordinador (Claude), que hizo las mediciones, el
banco con `hallazgos.v1`, M-25 y la ventana viva.

## Lo que queda abierto

- El **aviso a David** del cierre del bloque lo manda el coordinador.
- Las filas `SUA-05/*` de
  [followups.md](../agent-work/followups.md): la fila `SUA-02/raíz muda` pide
  instalar `feat/agent-work-integration` (`c7a58a6b`) en la Mini antes de SUA-09O,
  y las de #328 (el guard de `ci-rutas-control` con rutas de raíz y el `approved`
  sin `VEREDICTO`) siguen abiertas. Ninguna es bloqueante.
