# Runbook: despliegue por etapas del ruteo nativo de harnesses (14.7)

Contrato único de interrupción: el ruteo nativo vive en la variable
`CORRIDA_NATIVE_ROUTING` (`off` | `report` | `execute`). Con `off`, o sin
definir, ni el preflight ni las corridas lanzan harnesses nativos y el flujo
legacy queda intacto (14.6). El interruptor de vuelta atrás es **una sola
orden**, válida desde cualquier etapa:

```
launchctl setenv CORRIDA_NATIVE_ROUTING off
```

En una shell ya abierta, además `export CORRIDA_NATIVE_ROUTING=off`. Los
harnesses vivos al momento del corte se detienen con
`corrida.sh adaptador stop <id> <carril> <worker> <sesion>` (idempotente; la
forma corta con solo la sesión muere por uso y en reversa dejaría el harness
vivo). El corte es la primera respuesta ante cualquier humo o canary rojo: se
corta, se registra la evidencia y recién entonces se diagnostica.

El driver de humos es `scripts/mac/smoke-native-harnesses.sh`; su prueba en
falso, `scripts/tests/test-smoke-native-harnesses.sh`. Las barras medidas
viven en `scripts/mac/cli-modos.tsv` y el preflight hace NO APTO cualquier
binario seleccionable del registro sin barra medida (F2 de 14.7): un verde
del preflight significa que `adaptador start` puede arrancar.

## Etapa 1 — Selección en modo reporte

Qué permite: `CORRIDA_NATIVE_ROUTING=report`. El preflight corre sus sondas
de salud por worker y el selector anota su decisión; nada se ejecuta en un
carril. No se lanzan sesiones nativas.

Evidencia de promoción a Etapa 2: salida `APTO` del preflight con las seis
barras medidas en `cli-modos.tsv` (cero `unknown` entre los seleccionables),
salud `available` observada por sonda en los candidatos, y la decisión del
selector registrada por corrida. Comando de medición de humos que alimenta la
etapa siguiente:

```
bash scripts/mac/smoke-native-harnesses.sh --worker all --evidence-dir "$CORRIDA_STATE/native-smoke-<fecha>"
```

## Etapa 2 — Seis humos reales desechables

Qué permite: ejecutar el driver de humos contra CLIs reales en repos
desechables creados desde `origin/main`. Nada fusiona ni despliega.

Regla de aceptación por host (Task 10, Step 5): un host queda habilitado solo
con un resultado `passed` que pruebe arranque, autenticación, entrega,
transcripción, evento de completion, archivo y parada, con versión del
harness anotada. Un `unavailable` (binario ausente, sin autenticar, limitado)
deshabilita el host para ruteo vivo y se registra; jamás se cuenta como
`passed`. Un fallo de conducta en un harness que declara soportarlo es
bloqueante. Despliegue parcial: se habilitan solo los hosts con `passed`
siempre que sean al menos dos, incluyendo un revisor independiente.

Evidencia de promoción a Etapa 3: `resumen.json` del driver con los seis
workers, la tabla real `cli-modos.tsv` sin `unknown` entre los seis, y la
lista explícita de hosts habilitados y deshabilitados con su razón.

## Etapa 3 — Implementación y PR, sin merge ni despliegue

Qué permite: `CORRIDA_NATIVE_ROUTING=execute` con carriles de escritura para
implementar y abrir PRs revisados. Prohibido en esta etapa: merge, push a
ramas protegidas y despliegue. `main` queda fuera del allowlist de merge
(14.4) y la cruzada local precede al primer push.

Evidencia de promoción a Etapa 4: al menos un PR nativo completo (cruzada
local, CI vigente en el head, CodeRabbit leído o indisponibilidad declarada)
y la recepción del cambio por la ruta autorizada: recibo del kit o, con
`modo_recibo: ci-y-revisor` declarado en `preaprobaciones.v1.json` (kit
apagado, David 2026-09-28), CI verde y veredicto de revisor sobre el mismo
head. El merge lo ejecuta el closer autorizado, no un harness.

## Etapa 4 — Canary integral

Qué permite: un único cambio integral de bajo riesgo (desechable o
explícitamente de baja exposición) atraviesa la ruta completa: solicitud,
decisión del selector, carriles (máximo cuatro), revisión, PR, CI, CodeRabbit,
merge por la ruta autorizada, despliegue desde `origin/main` y observación
viva del comportamiento.

Evidencia de promoción a Etapa 5: el registro end-to-end del canary (selección,
terminal visible, merge SHA, SHA desplegado, observación viva) y, si la
observación viva falló, la reversa documentada verificada antes de reintentar.

## Etapa 5 — Ruteo general con tope de cuatro

Qué permite: ruteo nativo general con el tope de cuatro harnesses externos
activos por corrida (14.2). El corte de la sección anterior sigue vigente y
cualquier host que pierda su `passed` (cuota, auth, conducta) vuelve a
deshabilitado con evidencia, sin esperar a la siguiente medición completa.

## Registro de mediciones por host

Cada medición viva deja en la evidencia: worker, versión, comando, salida
relevante y valor final en `cli-modos.tsv`. Las barras se miden en la Mac; no
se infieren ni se copian. Un `unknown` en un seleccionable hace NO APTO el
preflight (F2), así que agregar un worker nuevo exige medir su barra antes de
pretender verde.
