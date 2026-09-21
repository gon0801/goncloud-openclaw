# Evidencia Fase 15 — CI completa sin siete minutos de espera

Fecha: 2026-09-21 · Corrida: fase15-ci · Repos: gon0801/goncloud-openclaw (+ gon0801/quality-kit).

## Resultado

**Objetivo logrado: 174 s (2 m 54 s) < 240 s.** Baseline 422 s (el plan cita 412 s del run 35547004899; re-medido con esta definición son 422 s: manda 422 y ambos quedan anotados). Reducción: −59 %.

Además: los PR de solo documentación ya no pagan la batería (carril fast por clasificación de archivos) y el push del PR de W corrió la batería completa repartida en 3 shards en ~2.5 min de pared.

## Medición 15.3 (run del SHA aprobado; el squash en main es otra corrida y no se mide)

- URL: https://github.com/gon0801/goncloud-openclaw/actions/runs/35635691765
- SHA: 344f96d3a08e2c5aa4909528bfac77e99cd2b68b (head del PR #119)
- Definición: primer job de calidad iniciado → gate terminado (misma definición del baseline).

| Job | Duración |
|---|---|
| clasificador (checks documentales incluidos) | 7 s |
| shards (1/3) — núcleo | 155 s |
| shards (2/3) — watchdog + preflight | 123 s |
| shards (3/3) — resto de shell + Node + sintaxis + corpus | 141 s |
| gate | 6 s |

Cuello de botella: shard 1 (155 s), por `test-corrida-nucleo.sh` (142.69 s medidos en el baseline: sigue siendo la prueba más cara, ahora en paralelo). Instalación: checkout + setup-node en cada shard, `Install openclaw` solo en el shard 3 (reparto documentado en el workflow); vive dentro de la duración de cada job. Cola de infraestructura (run creado → primer job): separada, no forma parte de la ventana.

## Cobertura de la corrida (unión de shards)

Artifacts `logs-run-checks-shard-1/2/3` (runs 35631255944 y 35635691765, auditados por el lead): **56 entradas, 0 duplicados, 0 faltantes, 0 sobrantes** contra el glob `scripts/tests/*.sh` del head (excluidos fixtures de datos bajo `scripts/tests/fixtures/`) + las 5 entradas no-shell (`sintaxis-summa-gate`, `bateria-summa-gate`, `sintaxis-tablero-runbook`, `bateria-tablero-runbook`, `verify-corpus`). Cada prueba exactamente una vez. Prueba roja: una sola ejecución con su primera salida y exit code conservados (fixture `roja.sh` del carril R).

## Carriles y PRs

| Ítem | PR | Merge | CI del head |
|---|---|---|---|
| Q0 · plan + runbook | goncloud-openclaw #113 | 38dcd2c | run 35551276640 |
| Q1 · S · clasificador + gate fast (15.0 openclaw) | #116 | 9ac48ee | run 35613246202 |
| Q2 · K · reglas 3 y 8 del kit (15.0 quality-kit) | quality-kit #14 | d35ad75 | run 35562962257 (macos+windows) |
| Q3 · R · inventario, logs y shards (15.1) | #117 | c303dea | run 35565658847 |
| Q4 · W · tres shards en CI (15.2) | #119 | 44de2f6 | run 35635691765 |

Post-merge en main: Q0 VERDE (CI del merge commit success), Q1 VERDE (9ac48ee), R sync en el gateway PRESENTE (c303dea), Q0 sync PRESENTE (38dcd2c).

## Decisión sobre O (15.4)

**Omitida**: la medición cumple el objetivo (174 s < 240 s). No hay superación por infraestructura que declarar ni esperas artificiales responsables que activar. Fila cerrada `cc:OMITIDA` con esta evidencia.

## Cierre documental de 15.5 (medición fast, <60 s de ejecución)

El PR de cierre toca SOLO los 4 paths allowlisted (`Plans.md`, `docs/evidence/fase15-ci-performance.md`, `.saikit/progress/15.json`, `.saikit/progress/15-sesiones.txt`). Su corrida: job `clasificador` con `carril=fast`, checks documentales en verde, job `shards` OMITIDO por clasificación fast, gate verde, SIN `Install openclaw`. Ejecución (job clasificador): ~10 s; sin instalar OpenClaw ni correr la batería. (URL del run citada en el cuerpo del PR de cierre; el tiempo se anota como informativo, no bloquea.)

## Evidencia de integración 15.0 (cambios coordinados openclaw + quality-kit)

- Los generadores del kit producen la regla 3 nueva (batería por SHA final del bloque de CÓDIGO; fast paga checks documentales) y la regla 8 nueva (clasificación POR ARCHIVOS con allowlist versionada, fail-closed) — test literal de consistencia entre ambos generadores en `tests/run-tests.ps1` (quality-kit #14).
- Regeneración contra temporales documentada en el PR #14 (`.saikit/scratch/K/regen-*` del worktree del carril; reproducible corriendo `install-ai-rules.ps1 -ClaudeMdPath <temp>` y `init-repo.ps1 -RepoPath <repo-temporal>`).
- Este PR de cierre es la demostración viva: clasifica fast con el clasificador de #116 y la allowlist que enumera sus 4 paths.
- No se creó `AGENTS.md` en openclaw (`git cat-file -e HEAD:AGENTS.md` falla).

## Poder discriminante (mutaciones del lead y de los revisores)

- S: fail-closed inresolubles→fast deja 1 caso ROJO; neutralizar `modos_sanos` deja EXACTAMENTE los 3 casos symlink/gitlink ROJO.
- R: neutralizar la validación de shard inválido deja ROJO el caso "4/3 salió 0".
- K: regla 3 revertida → su ancla desaparece del archivo generado (0 ocurrencias); regla 8 revertida → sus 2 anclas desaparecen (0) y la de regla 3 queda (1).
- W: gate sin `shards` en needs → ROJO; matriz real de 4 entradas → ROJO; cobertura por línea del filtro verificada por los revisores (cada fixture flípea exactamente su protección).

## Residuales no bloqueantes (a filas del plan futuro)

1. CodeRabbit Minor (S): regex de 5 columnas de Plans.md parte por `|` crudo y rechaza celdas con `\|` escapado (filas 9.1/13.2 reales).
2. CodeRabbit Minor (S): corregir una fila de 4 columnas deja la línea `-` vieja en rojo.
3. CodeRabbit Minor (S): captura de stdout sin salto final en el test del clasificador.
4. CodeRabbit Minor (R): el arnés del test exige `node` en PATH mientras el runner tiene fallbacks (`elegir_node`).
5. quality-kit: `README.md` (~L445) cita la regla 8 vieja (README fuera de la tabla del carril K).
6. W: borde documentado — sufijo inline de comentario (`fail-fast: true # contrato: fail-fast: false`) aceptado por el validador; repararlo exige parser YAML (decisión deliberada, fuera del modelo de amenaza).
7. Entorno del operador: `python3` de Homebrew roto (shim con exec loop) bloquea corridas locales completas de `test-corrida-nucleo.sh`; CI ubuntu es el gate (`brew reinstall python@3.14` sugerido).
8. quality-kit local: 4 fallos de `run-tests.ps1` en macOS sin `python` desnudo (preexistentes en master; CI macos los pasa).

## Proceso (desviaciones declaradas)

- El lead corrió como sesión zcode sin hooks de herramienta: el sello de veredicto (D16) fue reemplazado en la mitad de la corrida por el kit del Bloque A (recibo saikit-entrega.v1, summonaikit #345 mergeado durante la fase): Q0 y todo lo posterior mergean por recibos `APPROVE lead <sha>` con bloque JSON.
- Ronda 5 de W: revisión interna (subagente del lead, LIMPIO) por grok excedido (2×600 s) y kimi sin cuota; declarada en el recibo de #119.
- 2 bloqueantes de cross-review en S, 1 en W, 3 Majors de CodeRabbit (2 en S, 1 en W): todos corregidos; ninguna ronda terminó con el mismo bloqueante dos veces seguidas.
- CodeRabbit sin cuota en el PR #113 (Q0): no revisó, declarado en su recibo.
