#!/bin/bash
# cierre-de-fase.sh: dice VERDE o ROJO sobre el cierre de una fase, con un comando.
#
# Por que existe. Medido el 2026-09-17: claw reporto "la Fase 7 ya termino". El codigo
# estaba mergeado (PRs #62, #63, #65) y faltaban los cinco pasos posteriores del propio
# runbook: las ocho celdas de Plans.md seguian en cc:TODO, el plugin estaba en el repo
# pero no encendido en el gateway (la tarea de despliegue), sin Telegram de cierre, dos
# sesiones seguian marcadas mandandole avisos a claw, y un worktree y dos ramas sin
# limpiar. Nadie lo noto porque un merge es observable y el cierre no lo era.
#
# La regla que implementa: "terminado" se comprueba con un comando, no con un reporte.
# Nadie declara una fase cerrada sin que esto imprima VERDE.
#
# Uso:
#   bash scripts/cierre-de-fase.sh <fase>            # p. ej. 7
#   bash scripts/cierre-de-fase.sh <fase> --json     # una linea JSON por comprobacion
#
# Solo lectura: no toca el repo, ni el gateway, ni ninguna sesion.
#
# Env (todas opcionales, para las pruebas):
#   REPO=<ruta>            repo a mirar (default: el del propio script)
#   REF=<ref>              rama por defecto a leer (default: origin/main)
#   TMUX_BIN, OPENCLAW_BIN, GH_BIN
#   CIERRE_SIN_GATEWAY=1   no consulta el gateway; esa comprobacion sale unknown
#
# Salida: 0 si todo VERDE; 1 si hay al menos un ROJO. Un `unknown` no es ROJO: se
# declara, porque no poder comprobar algo no es lo mismo que comprobar que esta mal.
set -u

# Las variables de git heredadas (las exporta el hook de pre-commit, entre otros) hacen
# que `git -C "$REPO"` opere sobre OTRO repo: el comprobador miraria el plan equivocado
# y podria decir VERDE de una fase que no es. Medido el 2026-09-17, dos veces, en la
# prueba de este mismo script.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_PREFIX

FASE=${1:-}
JSON=0
[ "${2:-}" = "--json" ] && JSON=1
if [ -z "$FASE" ]; then
  echo "uso: bash scripts/cierre-de-fase.sh <fase> [--json]" >&2
  exit 2
fi

AQUI=$(cd "$(dirname "$0")/.." && pwd)
REPO=${REPO:-$AQUI}
REF=${REF:-origin/main}
TMUX_BIN=${TMUX_BIN:-/opt/homebrew/bin/tmux}
OPENCLAW_BIN=${OPENCLAW_BIN:-$HOME/.openclaw/bin/openclaw}
GH_BIN=${GH_BIN:-/opt/homebrew/bin/gh}

rojos=0
linea() { # $1 estado, $2 nombre, $3 detalle
  if [ "$JSON" = "1" ]; then
    # El detalle trae rutas y salidas de git: pueden venir con comillas, backslashes o
    # caracteres de control, y `tr -d` los cambiaria en vez de escaparlos, o dejaria un
    # JSON invalido. Se escapa de verdad.
    printf '{"estado":"%s","check":"%s","detalle":%s}\n' "$1" "$2" \
      "$(printf '%s' "$3" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  else
    printf '%-8s %-22s %s\n' "$1" "$2" "$3"
  fi
  [ "$1" = "ROJO" ] && rojos=$((rojos + 1))
  return 0
}

en_repo() { git -C "$REPO" "$@"; }

# (1) El plan: toda fila de la fase con su celda Status cerrada.
# Es el check que la Fase 7 fallaba: ocho filas en cc:TODO con todo mergeado.
plan=$(en_repo show "$REF:Plans.md" 2>/dev/null)
if [ -z "$plan" ]; then
  linea ROJO plan "no pude leer Plans.md en $REF"
else
  filas=$(printf '%s\n' "$plan" | grep -c -E "^\| $FASE\.[0-9]+[a-z]? \|") || true
  if [ "$filas" -eq 0 ]; then
    linea ROJO plan "Plans.md no tiene ninguna fila de la fase $FASE"
  else
    # Solo la ultima columna (Status). Buscar en la fila entera cuenta como abierta una
    # fila cerrada que mencione cc:TODO en su Contenido o en su DoD.
    estados=$(printf '%s\n' "$plan" | grep -E "^\| $FASE\.[0-9]+[a-z]? \|" | awk -F'|' '{print $(NF-1)}')
    abiertas=$(printf '%s\n' "$estados" | grep -c -E 'cc:(TODO|WIP)') || true
    if [ "$abiertas" -eq 0 ]; then
      linea VERDE plan "$filas filas, todas cerradas"
    else
      ids=$(printf '%s\n' "$plan" | grep -E "^\| $FASE\.[0-9]+[a-z]? \|" | awk -F'|' '$(NF-1) ~ /cc:(TODO|WIP)/ {gsub(/^ +| +$/,"",$2); printf "%s ", $2}')
      linea ROJO plan "$abiertas de $filas filas sin cerrar: $ids"
    fi
  fi
fi

# (2) Ramas de la fase en el remoto: una rama viva es trabajo que nadie recogio.
# Un `ls-remote` que falla no da ramas, y eso NO es lo mismo que no haber ramas: sin
# distinguirlo, una consulta caida cerraba la fase en verde. Y se miran tambien las
# locales: borrar la del servidor no borra la del disco.
# Las locales se miran SIEMPRE, aunque el remoto no conteste: si la consulta al
# servidor falla y con ella se salta tambien esta, una rama local de la fase pasa
# desapercibida y `unknown` no bloquea, asi que la fase cerraria en verde con trabajo
# suelto en el disco.
locales=$(en_repo for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null | grep -E "(^|/)fase$FASE(/|$)|fase$FASE-" || true)
if remotas=$(en_repo ls-remote --heads origin 2>/dev/null); then
  ramas=$(printf '%s\n' "$remotas" | awk '{print $2}' | sed 's|refs/heads/||' | grep -E "(^|/)fase$FASE(/|$)|fase$FASE-" || true)
  todas=$(printf '%s\n%s\n' "$ramas" "$locales" | grep . | sort -u || true)
  if [ -z "$todas" ]; then
    linea VERDE ramas "ninguna rama de la fase $FASE, ni en el remoto ni aqui"
  else
    linea ROJO ramas "quedan sin borrar: $(printf '%s' "$todas" | tr '\n' ' ')"
  fi
elif [ -n "$locales" ]; then
  linea ROJO ramas "sin respuesta del remoto, pero aqui quedan: $(printf '%s' "$locales" | tr '\n' ' ')"
else
  linea unknown ramas "no pude consultar el remoto; aqui no hay ninguna"
fi

# (3) Worktrees de la fase: los que abrio la corrida se quitan al cerrar.
wts=$(en_repo worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' | grep -E "f$FASE-|fase$FASE" || true)
if [ -z "$wts" ]; then
  linea VERDE worktrees "ninguno de la fase $FASE abierto"
else
  linea ROJO worktrees "siguen abiertos: $(printf '%s' "$wts" | tr '\n' ' ')"
fi

# (4) Sesiones marcadas: una sesion de la fase que sigue marcada le manda a claw un
# recordatorio cada media hora que nadie va a atender.
if [ ! -x "$TMUX_BIN" ]; then
  linea unknown sesiones "sin tmux en $TMUX_BIN"
else
  marcadas=""
  for s in $("$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null | grep -E "f$FASE-|fase$FASE" || true); do
    v=$("$TMUX_BIN" show-environment -t "$s" OPENCLAW_WATCH 2>/dev/null) || continue
    [ "$v" = "OPENCLAW_WATCH=1" ] && marcadas="$marcadas $s"
  done
  if [ -z "$marcadas" ]; then
    linea VERDE sesiones "ninguna sesion de la fase marcada"
  else
    linea ROJO sesiones "siguen marcadas:$marcadas"
  fi
fi

# (5) Despliegue: si alguna fila de la fase declara un plugin, tiene que estar en la
# configuracion que el gateway ve. Construir el plugin y no encenderlo fue justo lo
# que paso con tablero-runbook.
# El plugin se nombra en el encabezado de la fase o en sus filas, siempre como: plugin `<nombre>`.
bloque=$(printf '%s\n' "$plan" | awk -v f="$FASE" 'BEGIN{p="^## Fase "f"( |$|,|:|-)"} $0 ~ p {e=1} e&&/^## Fase /&&$0 !~ p&&NR>1{if(v)exit} {if(e){print; v=1}}')
[ -n "$bloque" ] || bloque=$(printf '%s\n' "$plan" | grep -E "^(\| $FASE\.[0-9]+[a-z]? \||## Fase $FASE)")
plugins=$(printf '%s\n' "$bloque" | grep -o -E 'plugin `[a-z0-9][a-z0-9-]*`' | sed -E 's/^plugin `//; s/`$//' | sort -u || true)
if [ -z "$plugins" ]; then
  linea VERDE despliegue "la fase no declara ningun plugin"
elif [ "${CIERRE_SIN_GATEWAY:-0}" = "1" ] || [ ! -x "$OPENCLAW_BIN" ]; then
  linea unknown despliegue "no consulte el gateway; plugins declarados: $(printf '%s' "$plugins" | tr '\n' ' ')"
else
  cfg=$(timeout 60 "$OPENCLAW_BIN" gateway call config.get --params '{}' --json 2>/dev/null)
  if [ -z "$cfg" ]; then
    linea unknown despliegue "el gateway no contesto"
  else
    faltan=""
    for p in $plugins; do
      printf '%s' "$cfg" | grep -qF "\"$p\"" || faltan="$faltan $p"
    done
    if [ -z "$faltan" ]; then
      linea VERDE despliegue "los plugins de la fase estan en la configuracion del gateway"
    else
      linea ROJO despliegue "construido pero NO encendido en el gateway:$faltan"
    fi
  fi
fi

# (7) El tablero publicado: lo que el dueno abre tiene que decir lo mismo que el
# documento versionado, y tiene que estar cerrado. Medido el 2026-09-18: este mismo
# comprobador imprimio VERDE mientras el tablero de la Fase 7 mostraba 75% y el carril
# de cierre en "implementando", porque ninguna comprobacion miraba la copia publicada.
# Es el fallo de la Fase 6 al reves: alli el tablero servia un fixture y el documento
# versionado era el bueno. Los dos son el mismo hueco: "cerrado" se declaraba sin
# mirar lo unico que el dueno ve. Una fase que se abre y se ve a medias no esta cerrada.
doc=$(en_repo show "$REF:.saikit/progress/$FASE.json" 2>/dev/null || true)
if [ -z "$doc" ]; then
  linea VERDE tablero "la fase $FASE no publica tablero"
elif [ "${CIERRE_SIN_GATEWAY:-0}" = "1" ] || [ ! -x "$OPENCLAW_BIN" ]; then
  linea unknown tablero "no consulte el gateway; hay documento versionado en $REF"
else
  vivo=$(timeout 60 "$OPENCLAW_BIN" gateway call runbook.progress.get \
           --params "{\"fase\":\"$FASE\"}" --timeout 30000 2>/dev/null)
  if [ -z "$vivo" ]; then
    linea unknown tablero "el gateway no contesto"
  else
    det=$(printf '%s' "$vivo" | CIERRE_DOC="$doc" python3 -c '
import json, os, sys

TERMINALES = {"mergeado", "atorado", "revertido", "omitido"}

class Informe(Exception):
    pass

def resumen(d, de_donde):
    d = d.get("result", d)
    d = d.get("doc", d)
    # Un documento sin carriles bien formados se normalizaba a [], y entonces "ningun
    # carril abierto" salia cierto por vacio: dos documentos con la misma fase y el
    # mismo cierre.at pasaban sin que nadie hubiera mirado un solo carril. Es el mismo
    # falso verde que esta comprobacion existe para matar, asi que la forma se valida
    # antes de normalizarla y, si no cuadra, se declara en vez de darla por buena.
    cs = d.get("carriles")
    if not isinstance(cs, list) or not cs:
        raise Informe("UNKNOWN " + de_donde + " no trae una lista de carriles; no hay nada que comparar")
    pares = []
    for c in cs:
        if not isinstance(c, dict):
            raise Informe("UNKNOWN " + de_donde + " trae un carril que no es un objeto")
        cid, est = c.get("id"), c.get("estado")
        if not isinstance(cid, str) or not cid or not isinstance(est, str) or not est:
            raise Informe("UNKNOWN " + de_donde + " trae un carril sin id o sin estado")
        pares.append((cid, est))
    return {"fase": d.get("fase"), "at": (d.get("cierre") or {}).get("at"), "carriles": sorted(pares)}

try:
    ver = resumen(json.loads(os.environ["CIERRE_DOC"]), "el documento versionado")
except Informe as e:
    print(str(e))
    raise SystemExit
except Exception:
    print("UNKNOWN no pude leer el documento versionado")
    raise SystemExit

bruto = sys.stdin.read()
i = bruto.find("{")
try:
    viv = resumen(json.loads(bruto[i:]), "el tablero publicado")
except Informe as e:
    print(str(e))
    raise SystemExit
except Exception:
    print("UNKNOWN el gateway no devolvio un documento legible")
    raise SystemExit

abiertos = [i2 for i2, e in viv["carriles"] if e not in TERMINALES]
if abiertos:
    print("ROJO el tablero publicado muestra carriles sin terminar: " + " ".join(abiertos))
elif not viv["at"]:
    print("ROJO el tablero publicado no trae cierre.at: quien lo abra ve la fase en curso")
elif viv != ver:
    print("ROJO el tablero publicado no dice lo mismo que el documento versionado")
else:
    print("OK coincide con el documento versionado y esta cerrado")
')
    case "$det" in
      "OK "*)      linea VERDE   tablero "${det#OK }" ;;
      "UNKNOWN "*) linea unknown tablero "${det#UNKNOWN }" ;;
      "ROJO "*)    linea ROJO    tablero "${det#ROJO }" ;;
      *)           linea unknown tablero "no pude comparar el tablero publicado" ;;
    esac
  fi
fi

# (6) CI de la rama por defecto sobre su punta: una fase no cierra dejandola en rojo.
if [ ! -x "$GH_BIN" ]; then
  linea unknown ci "sin gh en $GH_BIN"
else
  url=$(en_repo remote get-url origin 2>/dev/null | sed 's|\.git$||')
  slug="$(basename "$(dirname "$url")")/$(basename "$url")"
  # Si la consulta falla o expira despues de haber escrito algo, aceptar su salida daba
  # VERDE sin haber comprobado nada. Primero el exito de la consulta, luego su contenido.
  if ! cc=$(timeout 90 "$GH_BIN" run list --repo "$slug" --branch "${REF#origin/}" --limit 1 --json status,conclusion --jq '.[0] | "\(.status) \(.conclusion // "")"' 2>/dev/null); then
    cc=""
  fi
  case "$cc" in
    "completed success") linea VERDE ci "la rama por defecto esta en verde" ;;
    "") linea unknown ci "no pude leer el estado de CI" ;;
    *) linea ROJO ci "ultima corrida: $cc" ;;
  esac
fi

if [ "$JSON" = "0" ]; then
  echo
  if [ "$rojos" -eq 0 ]; then
    echo "VERDE: la fase $FASE puede declararse cerrada"
  else
    echo "ROJO: la fase $FASE NO esta cerrada ($rojos comprobacion(es) en rojo)"
  fi
fi
[ "$rojos" -eq 0 ]
