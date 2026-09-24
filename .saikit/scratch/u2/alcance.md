# U2 — carril I (instalacion y cierre concurrente)

Fuente autoritativa: fila U2 de Plans.md + plan `docs/superpowers/plans/2026-09-21-fase9-cierre.md`
+ runbook `docs/runbooks/autopilot-fase9.md`. Rama `fase9/instalacion-cierre` desde
origin/main 978d18b (verificado con git log antes de trabajar).

## Por que solo el carril I

U2 pide "cerrar solo lo que falte de la fase y probar de punta a punta algo chico
y acotado". Estado medido en origin/main:

- D (9.7, 9.13): 9.7 integrada por PR #100 (merge f87f27e); 9.13 con prueba viva.
  Nada que implementar aqui.
- I (9.10, 9.16): FALTAN. Sin 9.10 no hay instalacion desde main y el simulacro
  (S/9.9) no puede arrancar — el runbook Q4 lo dice literal ("no existe aun
  scripts/mac/instalar-mac.sh"). Es el desbloqueador.
- U (9.11, 9.12): FALTAN (sin agents/usuario, sin check usuario en cierre-de-fase).
  Quedan pendientes para el siguiente turno/carril.
- S (9.9): medicion viva, pendiente de I + instalacion real (la instalacion real
  en esta Mac NO se hace en este turno: seria deploy; solo se prueba en HOME
  de mentira).

Alcance de este turno: 9.10 (instalador + test) y 9.16 (cierre acotado + caso),
dos commits separados, pruebas focalizadas, push normal, sin merge.

## Decisiones tomadas del repo (no inventadas)

- Manifiesto del instalador: corrida.sh + corrida/*.sh + cli-modos.tsv + agentes
  tmux + watcher + plist del watchdog global + tmux.conf + linea de .zshrc
  (bloque manual del runbook Q4 + `~/bin` vivo de la Mac como oracle).
- Latido viejo excluido por diseno (PR #110) y por el plan ("no carga
  ai.goncloud.corrida-latido").
- Celdas cc:TODO de Plans.md NO se tocan: el plan de cierre dice que se
  actualizan juntas en el PR final de ledger.
