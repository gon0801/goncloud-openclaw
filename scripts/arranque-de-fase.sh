#!/usr/bin/env bash
# arranque-de-fase.sh: dice VERDE o ROJO sobre el ARRANQUE de una fase, con un comando.
#
# POR QUE EXISTE. Medido el 2026-09-18: claw reporto "la Fase 9 ya termino". No solo no
# habia terminado -- 13 de 13 filas seguian abiertas -- es que nunca la arranco del todo:
# la tarea 0.4 del runbook manda crear dos crons de seguimiento, `corrida-vigia-<fase>` y
# `corrida-empuje-<fase>`, y NINGUNO existia. Ese es el paso que hace que alguien se
# entere cuando un carril se atora. Sin el no hay alarma, y sin alarma nadie se entera de
# que no hay alarma: se perdieron ocho horas.
#
# La regla que implementa, hermana de la de cierre: "arrancada" se comprueba con un
# comando, no con un reporte. Nadie declara una fase en marcha sin que esto imprima
# VERDE, y el reporte de arranque ES esta salida, no una frase.
#
# Por que no basta con escribirlo en el runbook: ya estaba escrito. Lo que faltaba no era
# la instruccion sino la comprobacion. Un paso saltado no se ve; una linea ROJO si.
#
# QUE NO COMPRUEBA, declarado: no puede saber si alguien LEYO el runbook. Comprueba lo
# que leerlo obliga a producir, que es lo unico observable. Un arranque que deje las
# cinco lineas en verde hizo el trabajo del arranque, lo haya leido o no.
#
# Uso:
#   bash scripts/arranque-de-fase.sh <fase>            # p. ej. 9
#   bash scripts/arranque-de-fase.sh <fase> --json     # una linea JSON por comprobacion
#
# Solo lectura: no toca el repo, ni el gateway, ni ninguna sesion, ni ningun cron.
#
# Env (todas opcionales, para las pruebas):
#   REPO=<ruta>              repo a mirar (default: el del propio script)
#   REF=<ref>                rama por defecto a leer (default: origin/main)
#   TMUX_BIN, OPENCLAW_BIN
#   ARRANQUE_SIN_GATEWAY=1   no consulta el gateway; esas comprobaciones salen unknown
#
# Salida: 0 si todo VERDE; 1 si hay al menos un ROJO. Un `unknown` no es ROJO: se
# declara, porque no poder comprobar algo no es lo mismo que comprobar que esta mal.
set -u

# Las variables de git heredadas (las exporta el hook de pre-commit, entre otros) hacen
# que `git -C "$REPO"` opere sobre OTRO repo. Mismo cinturon que en cierre-de-fase.sh,
# donde esto se midio dos veces el 2026-09-17.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_PREFIX

FASE=${1:-}
JSON=0
[ "${2:-}" = "--json" ] && JSON=1
if [ -z "$FASE" ]; then
  echo "uso: bash scripts/arranque-de-fase.sh <fase> [--json]" >&2
  exit 2
fi
case "$FASE" in
  *[!0-9.]*) echo "fase invalida: '$FASE' (solo digitos y punto)" >&2; exit 2 ;;
esac

# El punto de una fase como `9.1` es COMODIN en grep -E: sin escapar, el patron del
# plan no matchearia sus filas y saldria ROJO "no hay nada que arrancar" de una fase
# que si existe. Hallazgo de kimi, 2026-09-18.
FASE_RE=$(printf '%s' "$FASE" | sed 's/\./\\./g')

AQUI=$(cd "$(dirname "$0")/.." && pwd)
REPO=${REPO:-$AQUI}
REF=${REF:-origin/main}
TMUX_BIN=${TMUX_BIN:-/opt/homebrew/bin/tmux}
OPENCLAW_BIN=${OPENCLAW_BIN:-$HOME/.openclaw/bin/openclaw}

rojos=0
desconocidos=0
linea() { # $1 estado, $2 nombre, $3 detalle
  if [ "$JSON" = "1" ]; then
    printf '{"estado":"%s","check":"%s","detalle":%s}\n' "$1" "$2" \
      "$(printf '%s' "$3" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  else
    printf '%-8s %-22s %s\n' "$1" "$2" "$3"
  fi
  [ "$1" = "ROJO" ] && rojos=$((rojos + 1))
  [ "$1" = "unknown" ] && desconocidos=$((desconocidos + 1))
  return 0
}

en_repo() { git -C "$REPO" "$@"; }

# (1) La fase existe en el plan. Arrancar una fase que no esta planeada no es arrancar
# nada; sin esto, cualquier numero saldria VERDE por vacio en las demas lineas.
plan=$(en_repo show "$REF:Plans.md" 2>/dev/null)
if [ -z "$plan" ]; then
  linea unknown plan "no pude leer Plans.md en $REF"
else
  filas=$(printf '%s\n' "$plan" | grep -c -E "^\| $FASE_RE\.[0-9]+[a-z]? \|") || true
  if [ "$filas" -eq 0 ]; then
    linea ROJO plan "Plans.md no tiene ninguna fila de la fase $FASE: no hay nada que arrancar"
  else
    linea VERDE plan "$filas filas en el plan"
  fi
fi

# (2) El primer progreso, enviado. Es la tarea 0.3 y es lo que hace que el dueno pueda
# mirar sin preguntarle a nadie. Se consulta el gateway, no el disco: escribir el archivo
# y no enviarlo deja al dueno sin tablero, que es el caso de la Fase 6 (dos dias con un
# fixture servido porque el envio fallaba y nadie lo miraba).
if [ "${ARRANQUE_SIN_GATEWAY:-0}" = "1" ] || [ ! -x "$OPENCLAW_BIN" ]; then
  linea unknown progreso "no consulte el gateway"
else
  if ! vivo=$(timeout 60 "$OPENCLAW_BIN" gateway call runbook.progress.get \
                --params "{\"fase\":\"$FASE\"}" --timeout 30000 2>/dev/null); then
    vivo=""
  fi
  if [ -z "$vivo" ]; then
    linea unknown progreso "el gateway no contesto"
  elif printf '%s' "$vivo" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
    linea VERDE progreso "el tablero de la fase $FASE ya sirve su primer avance"
  else
    linea ROJO progreso "el gateway no tiene avance de la fase $FASE: la tarea 0.3 no se hizo"
  fi
fi

# (3) Los DOS crons de seguimiento. Es la tarea 0.4, y es la que falto el 2026-09-18.
# Sin ellos nadie se entera de que un carril se atoro: la fase corre a ciegas.
if [ "${ARRANQUE_SIN_GATEWAY:-0}" = "1" ] || [ ! -x "$OPENCLAW_BIN" ]; then
  linea unknown vigilantes "no consulte el gateway"
else
  if ! crons=$(timeout 60 "$OPENCLAW_BIN" gateway call cron.list --params '{}' --timeout 30000 2>/dev/null); then
    crons=""
  fi
  if [ -z "$crons" ]; then
    linea unknown vigilantes "el gateway no contesto"
  else
    faltan=""
    apagados=""
    for c in "corrida-vigia-$FASE" "corrida-empuje-$FASE"; do
      est=$(printf '%s' "$crons" | CRON="$c" python3 -c '
import json, os, sys
bruto = sys.stdin.read(); i = bruto.find("{")
try:
    d = json.loads(bruto[i:])
except Exception:
    print("ILEGIBLE"); raise SystemExit
r = d.get("result", d)
for j in (r.get("jobs") or r.get("items") or []):
    if j.get("name") == os.environ["CRON"]:
        print("ON" if j.get("enabled") else "OFF"); raise SystemExit
print("FALTA")
')
      case "$est" in
        ON) : ;;
        OFF) apagados="$apagados $c" ;;
        ILEGIBLE) faltan="ILEGIBLE"; break ;;
        *) faltan="$faltan $c" ;;
      esac
    done
    if [ "$faltan" = "ILEGIBLE" ]; then
      linea unknown vigilantes "no pude leer la lista de crons"
    elif [ -n "$faltan" ]; then
      linea ROJO vigilantes "sin crear:$faltan — la fase corre sin alarma y nadie se entera si un carril se atora"
    elif [ -n "$apagados" ]; then
      linea ROJO vigilantes "creados pero apagados:$apagados"
    else
      linea VERDE vigilantes "corrida-vigia-$FASE y corrida-empuje-$FASE creados y encendidos"
    fi
  fi
fi

# (4) El apunte de sesiones. Es la otra mitad de 0.3, y es lo que Q5 usa para limpiar:
# sin el, al cerrar nadie sabe que sesiones ni que crons hay que quitar. Vive en el
# worktree del lead, asi que se busca en todos los worktrees del repo, no solo aqui.
rel=".saikit/progress/$FASE-sesiones.txt"
hallado=""
# Se lee linea a linea: partir por espacios rompe cualquier ruta que los tenga y
# produce un ROJO falso de "no existe en ningun worktree". Hallazgo de kimi, 2026-09-18.
while IFS= read -r w; do
  [ -n "$w" ] || continue
  [ -f "$w/$rel" ] && { hallado="$w/$rel"; break; }
done <<EOF
$(en_repo worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
EOF
if [ -z "$hallado" ]; then
  linea ROJO sesiones "no existe $rel en ningun worktree: al cerrar nadie sabra que quitar"
elif ! grep -qE '^lead' "$hallado" 2>/dev/null; then
  linea ROJO sesiones "$hallado existe pero no tiene la linea del lead"
else
  n=$(grep -c . "$hallado" 2>/dev/null || echo 0)
  linea VERDE sesiones "$hallado con $n linea(s), la del lead incluida"
fi

# (5) La sesion del lead, viva y marcada. Es la tarea 0.2. Sin la marca, el vigilante no
# la mira: el 2026-09-17 una sesion sin marcar dejo una pregunta 6 h 54 min sin contestar.
if [ ! -x "$TMUX_BIN" ]; then
  linea unknown lead "sin tmux en $TMUX_BIN"
else
  cands=$("$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null | grep -E "wt-f$FASE_RE-" || true)
  if [ -z "$cands" ]; then
    linea ROJO lead "ninguna sesion de tmux con 'wt-f$FASE-' en el nombre: el lead no esta lanzado"
  else
    marcadas=""
    for s in $cands; do
      v=$("$TMUX_BIN" show-environment -t "$s" OPENCLAW_WATCH 2>/dev/null) || continue
      [ "$v" = "OPENCLAW_WATCH=1" ] && marcadas="$marcadas $s"
    done
    if [ -z "$marcadas" ]; then
      linea ROJO lead "sesiones de la fase sin marcar: $(printf '%s' "$cands" | tr '\n' ' ')— el vigilante no las mira"
    else
      linea VERDE lead "sesion del lead viva y marcada:$marcadas"
    fi
  fi
fi

if [ "$JSON" = "0" ]; then
  echo
  if [ "$rojos" -eq 0 ] && [ "$desconocidos" -gt 0 ]; then
    # Un `unknown` no bloquea (misma politica que cierre-de-fase.sh), pero el resumen
    # tiene que distinguir "todo comprobado" de "no pude comprobar lo esencial". Decir
    # VERDE a secas con el gateway caido es prometer mas de lo que se miro, que es
    # justo el falso verde contra el que existe este script. Hallazgo de kimi, 2026-09-18.
    echo "VERDE con reservas: la fase $FASE puede estar arrancada, pero $desconocidos comprobacion(es) no se pudieron hacer"
  elif [ "$rojos" -eq 0 ]; then
    echo "VERDE: la fase $FASE esta arrancada"
  else
    echo "ROJO: la fase $FASE NO esta arrancada ($rojos comprobacion(es) en rojo)"
  fi
fi
[ "$rojos" -eq 0 ]
