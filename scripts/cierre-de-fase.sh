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
    # timeout 30 (F1): un python3 colgado del PATH no puede trabar el cierre. Fallback r2:
    # si el parseo falla o vence, el detalle sale como string JSON vacio y no vacio de
    # verdad: un detalle vacio dejaba esta linea con "detalle":} -- JSON invalido.
    printf '{"estado":"%s","check":"%s","detalle":%s}\n' "$1" "$2" \
      "$(printf '%s' "$3" | timeout 30 python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' || printf '%s' '""')"
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

# (8) Reloj global y vigias legados: un corrida-vigia-<fase> restante es un
# resto sin migrar y bloquea. avance-tareas se resuelve UNA vez por
# declarationKey exacta; si esta presente, su scratch dice si queda otro
# trabajo activo: con otro trabajo el reloj se conserva (VERDE); si solo queda
# esta fase o nada, el reloj esta rancio (ROJO). Un scratch ilegible es un
# fallo indeterminado (ROJO). El scratch se lee por UUID, nunca por nombre.
if [ "${CIERRE_SIN_GATEWAY:-0}" = "1" ] || [ ! -x "$OPENCLAW_BIN" ]; then
  linea unknown reloj "no consulte el gateway"
else
  if ! crons=$(timeout 60 "$OPENCLAW_BIN" cron list --all --json 2>/dev/null); then
    crons=""
  fi
  if [ -z "$crons" ]; then
    linea unknown reloj "el gateway no contesto"
  else
    # timeout 30 (F1): un python3 colgado del PATH no puede trabar el cierre. Fallback r2:
    # al fallar o vencer sale el string JSON vacio y el check cae en unknown (el case
    # de abajo lo recibe junto con ILEGIBLE y el vacio).
    reloj=$(printf '%s' "$crons" | FASE="$FASE" timeout 30 python3 -c '
import json, os, sys
bruto = sys.stdin.read(); i = bruto.find("{")
try:
    d = json.loads(bruto[i:])
except Exception:
    print("ILEGIBLE"); raise SystemExit
r = d.get("result", d)
jobs = r.get("jobs") or r.get("items") or []
if not isinstance(jobs, list):
    print("ILEGIBLE"); raise SystemExit
fase = os.environ["FASE"]
legados = sorted(j.get("name", "") for j in jobs
                 if isinstance(j, dict) and j.get("name") == "corrida-vigia-" + fase)
reloj = [j for j in jobs
         if isinstance(j, dict) and j.get("declarationKey") == "avance-tareas"]
if legados:
    print("LEGADO " + " ".join(legados)); raise SystemExit
if not reloj:
    print("AUSENTE"); raise SystemExit
if len(reloj) > 1:
    print("DUP"); raise SystemExit
print("UUID " + str(reloj[0].get("id", "")))
' || printf '%s' '""')
    case "$reloj" in
      ILEGIBLE|""|'""') linea unknown reloj "no pude leer la lista de crons";;
      AUSENTE) linea VERDE reloj "sin reloj global: nada que retirar";;
      DUP*) linea ROJO reloj "avance-tareas duplicado por declarationKey: no se adivina cual es el bueno";;
      LEGADO*) linea ROJO reloj "quedan vigias legados sin migrar: ${reloj#LEGADO }";;
      UUID*)
        uuid="${reloj#UUID }"
        if [ -z "$uuid" ]; then
          linea unknown reloj "el reloj no trae id; no se puede leer su scratch"
        elif ! scratch=$(timeout 60 "$OPENCLAW_BIN" cron scratch "$uuid" 2>/dev/null) || [ -z "$scratch" ]; then
          linea ROJO reloj "reloj presente pero su scratch no se pudo leer: fallo indeterminado"
        else
          # timeout 30 (F1): un python3 colgado del PATH no puede trabar el cierre. Fallback r2:
          # al fallar o vencer sale el string JSON vacio y el check lo declara como
          # fallo indeterminado (la rama *) del case de abajo).
          uso=$(printf '%s' "$scratch" | FASE="$FASE" timeout 30 python3 -c '
import json, os, sys
bruto = sys.stdin.read(); i = bruto.find("{")
try:
    d = json.loads(bruto[i:])
except Exception:
    print("MAL"); raise SystemExit
nodo = d
if not (isinstance(nodo, dict) and nodo.get("schema") == "seguimiento-clock.v1"):
    for k in ("result", "scratch", "data", "state"):
        v = nodo.get(k) if isinstance(nodo, dict) else None
        if isinstance(v, dict) and v.get("schema") == "seguimiento-clock.v1":
            nodo = v
            break
if not (isinstance(nodo, dict) and nodo.get("schema") == "seguimiento-clock.v1"):
    print("MAL"); raise SystemExit
trab = nodo.get("trabajosActivos")
if not isinstance(trab, list) or any(not isinstance(t, str) for t in trab):
    print("MAL"); raise SystemExit
fase = os.environ["FASE"]
print("OTROS" if any(t != "fase:" + fase for t in trab) else "SOLO")
' || printf '%s' '""')
          case "$uso" in
            OTROS) linea VERDE reloj "reloj compartido con otro trabajo activo: se conserva";;
            SOLO) linea ROJO reloj "reloj global presente y rancio: retirarlo al cerrar lo ultimo";;
            *) linea ROJO reloj "reloj presente pero su scratch no se pudo leer: fallo indeterminado";;
          esac
        fi
        ;;
    esac
  fi
fi
# (7) El tablero publicado: lo que el dueno abre tiene que decir lo mismo que el
# documento versionado, y tiene que estar cerrado. Medido el 2026-09-18: este mismo
# comprobador imprimio VERDE mientras el tablero de la Fase 7 mostraba 75% y el carril
# de cierre en "implementando", porque ninguna comprobacion miraba la copia publicada.
# Es el fallo de la Fase 6 al reves: alli el tablero servia un fixture y el documento
# versionado era el bueno. Los dos son el mismo hueco: "cerrado" se declaraba sin
# mirar lo unico que el dueno ve. Una fase que se abre y se ve a medias no esta cerrada.
# El nombre canonico es `<fase>.json`, pero la Fase 6 quedo versionada como
# `fase6.json` y renombrarla romperia las citas de los runbooks. Se miran los dos: con
# uno solo, `cierre-de-fase.sh 6` imprimia "la fase 6 no publica tablero" -- VERDE por
# ausencia -- sobre una fase que publica y que el dueno tiene abierta en 7/7.
# Y antes de concluir "no publica", la rama por defecto tiene que resolver: si no
# resuelve, `show` falla igual que si el archivo no existiera, y un git roto quedaba
# indistinguible de una fase sin tablero. Los dos hallazgos son del revisor del lead,
# 2026-09-18, sobre esta misma comprobacion.
if ! en_repo rev-parse --verify -q "$REF^{commit}" >/dev/null 2>&1; then
  doc=""
  ref_ok=0
else
  ref_ok=1
  doc=""
  habia=0
  for cand in ".saikit/progress/$FASE.json" ".saikit/progress/fase$FASE.json"; do
    if en_repo cat-file -e "$REF:$cand" 2>/dev/null; then
      habia=1
      doc=$(en_repo show "$REF:$cand" 2>/dev/null || true)
      [ -n "$doc" ] && break
    fi
  done
fi
if [ "$ref_ok" = "0" ]; then
  linea unknown tablero "no pude leer $REF; no se si la fase $FASE publica tablero"
elif [ -z "$doc" ] && [ "${habia:-0}" = "1" ]; then
  # El archivo esta versionado pero vino vacio: existe un tablero y no pude leerlo.
  # Caer en la rama verde aqui seria decir "no publica" de una fase que si publica.
  linea unknown tablero "la fase $FASE tiene documento versionado pero vino vacio"
elif [ -z "$doc" ]; then
  linea VERDE tablero "la fase $FASE no publica tablero"
elif [ "${CIERRE_SIN_GATEWAY:-0}" = "1" ] || [ ! -x "$OPENCLAW_BIN" ]; then
  linea unknown tablero "no consulte el gateway; hay documento versionado en $REF"
else
  # Si la consulta falla despues de haber escrito algo, aceptar su stdout daria por
  # buena una salida parcial. La comprobacion (6) de CI ya aprendio esto; esta tambien:
  # primero el exito de la consulta, luego su contenido.
  if ! vivo=$(timeout 60 "$OPENCLAW_BIN" gateway call runbook.progress.get \
           --params "{\"fase\":\"$FASE\"}" --timeout 30000 2>/dev/null); then
    vivo=""
  fi
  if [ -z "$vivo" ]; then
    linea unknown tablero "el gateway no contesto"
  else
    # timeout 30 (F1): un python3 colgado del PATH no puede trabar el cierre. Fallback r2:
    # al fallar o vencer sale el string JSON vacio y el check cae en unknown (la rama
    # *) del case de abajo).
    det=$(printf '%s' "$vivo" | CIERRE_DOC="$doc" timeout 30 python3 -c '
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
    # Solo fase, cierre.at y los carriles dejaban fuera todo lo que el dueno lee ARRIBA
    # del tablero: el titulo, la frase de siguiente paso y el banner rojo de atencion.
    # Un tablero vivo con "atencion requerida: algo roto" pasaba por coincidente.
    # `cierre.resumen` queda fuera a proposito y declarado: hoy diverge de forma legitima
    # entre el vivo y el versionado de la Fase 6 (244 contra 268 caracteres del mismo
    # texto), y meterlo pintaria de rojo una fase que si esta cerrada.
    a = d.get("atencion_requerida") or {}
    return {
        "fase": d.get("fase"),
        "at": (d.get("cierre") or {}).get("at"),
        "titulo": d.get("titulo"),
        "siguiente_paso": d.get("siguiente_paso"),
        "atencion": a.get("necesaria"),
        "carriles": sorted(pares),
    }

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
elif viv["atencion"]:
    # Coincidir no basta: si los DOS lados declaran atencion_requerida, el resumen
    # cuadra y la comprobacion decia OK sobre un tablero que le pinta al dueno el
    # banner rojo arriba de todo. Una fase que pide atencion no esta cerrada, este o
    # no de acuerdo el documento versionado.
    print("ROJO el tablero publicado pide atencion arriba de todo: una fase que la pide no esta cerrada")
elif viv != ver:
    difieren = [k for k in ver if viv.get(k) != ver.get(k)]
    print("ROJO el tablero publicado no dice lo mismo que el documento versionado; difiere en: " + ", ".join(difieren))
else:
    print("OK fase, cierre, titulo, siguiente paso, atencion y carriles coinciden con lo versionado")
' || printf '%s' '""')
    case "$det" in
      "OK "*)      linea VERDE   tablero "${det#OK }" ;;
      "UNKNOWN "*) linea unknown tablero "${det#UNKNOWN }" ;;
      "ROJO "*)    linea ROJO    tablero "${det#ROJO }" ;;
      *)           linea unknown tablero "no pude comparar el tablero publicado" ;;
    esac
  fi
fi

# (9) Entregables de la fase: los carriles del documento de progreso versionado. La
# instalacion y el simulacro son carriles sin PR: un remoto con todos los PR en MERGED
# no los prueba (medido 2026-09-17 en la Fase 7: todo mergeado y CI en verde faltaban el
# despliegue y las celdas; en la Fase 9 el simulacro era el entregable que quedaba). Un
# carril que no llego a estado terminal es un entregable sin terminar y bloquea el cierre,
# aunque todos los PR de la fase digan MERGED. Sin documento no hay entregables declarados
# y la fase no se bloquea por lo que no declaro; un documento ilegible o sin carriles se
# declara unknown, mismo falso verde que (12g) mato en el tablero publicado. Un
# carril ATORADO tampoco esta terminado: es un entregable pendiente con motivo.
if [ "$ref_ok" = "0" ]; then
  linea unknown entregables "no pude leer $REF; no se que entregables declara la fase $FASE"
elif [ -z "$doc" ]; then
  # Distinto de la rama de (7): si el documento EXISTE versionado pero no se
  # pudo leer (vacio, corrupto), no es "sin entregables declarados" sino un
  # unknown (CodeRabbit/revisor 2026-09-22: con un doc de 0 bytes el cierre
  # salia VERDE).
  if [ "${habia:-0}" = "1" ]; then
    linea unknown entregables "la fase $FASE tiene documento versionado pero no se pudo leer"
  else
    linea VERDE entregables "sin documento de progreso; sin entregables declarados"
  fi
else
  # timeout 30 (F1): un python3 colgado del PATH no puede trabar el cierre. Fallback r2:
  # al fallar o vencer sale el string JSON vacio y el check cae en unknown (la rama *).
  det=$(printf '%s' "$doc" | FASE="$FASE" timeout 30 python3 -c '
import json, os, sys
# atorado NO cuenta: una instalacion o un simulacro atorados son justamente el
# entregable pendiente (medido 2026-09-22: con la instalacion atorada el cierre
# salia VERDE). Terminal aqui es: hecho, revertido declarado u omitido por el
# operador; lo demas es un entregable con nombre y motivo.
TERMINALES = {"mergeado", "revertido", "omitido"}
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print("UNKNOWN no pude leer el documento de progreso")
    raise SystemExit
# El documento tiene que ser EL de esta fase: un progreso de otra fase con
# carriles terminales no acredita los entregables de esta (CodeRabbit 2026-09-22).
if d.get("fase") != os.environ["FASE"]:
    print("ROJO el documento de progreso no corresponde a la fase " + os.environ["FASE"])
    raise SystemExit
cs = d.get("carriles")
if not isinstance(cs, list) or not cs:
    print("UNKNOWN el documento no trae una lista de carriles; no hay entregables que leer")
    raise SystemExit
vivos = []
for c in cs:
    if not isinstance(c, dict):
        print("UNKNOWN el documento trae un carril que no es un objeto")
        raise SystemExit
    cid, est = c.get("id"), c.get("estado")
    if not isinstance(cid, str) or not cid or not isinstance(est, str) or not est:
        print("UNKNOWN el documento trae un carril sin id o sin estado")
        raise SystemExit
    if est not in TERMINALES:
        # El detalle es lo que el lead va a ir a terminar: "I" solo no dice nada,
        # "Instalacion" si. El nombre viaja cuando el carril lo trae.
        nom = c.get("nombre")
        vivos.append(cid + (" (" + nom + ")" if isinstance(nom, str) and nom else ""))
if vivos:
    print("ROJO entregables sin terminar: " + " ".join(vivos))
else:
    print("OK %d carriles, todos en estado terminal" % len(cs))
' || printf '%s' '""')
  case "$det" in
    "OK "*)      linea VERDE entregables "${det#OK }" ;;
    "UNKNOWN "*) linea unknown entregables "${det#UNKNOWN }" ;;
    "ROJO "*)    linea ROJO entregables "${det#ROJO }" ;;
    *)           linea unknown entregables "no pude leer los entregables del documento de progreso" ;;
  esac
fi

# (10) usuario: por cada fila de la fase que declara una promesa observable (slot 16
# de la skill autopilot-runbook, literal "Promesa: <...> — ruta: <...>." dentro de su
# celda de Contenido), tiene que existir un bloque "## <fase>.<tarea>" que termine en
# una linea FUNCIONA dentro de docs/evidence/usuario-<fase>-*.md. Una fila sin promesa
# (sin la linea, o con "Promesa: sin promesa observable.") no exige nada, y eso se dice
# en el detalle en vez de darlo por bueno en silencio. Solo se lee la linea literal:
# prosa suelta en otra parte de la fila no cuenta como promesa ni como su ausencia.
if [ "$ref_ok" = "0" ]; then
  linea unknown usuario "no pude leer $REF; no se que filas de la fase $FASE declaran promesa"
elif [ -z "$plan" ]; then
  linea unknown usuario "no pude leer Plans.md en $REF"
else
  filas_fase=$(printf '%s\n' "$plan" | grep -E "^\| $FASE\.[0-9]+[a-z]? \|") || true
  evidencia=""
  if archivos=$(en_repo ls-tree -r --name-only "$REF" -- docs/evidence 2>/dev/null | grep -E "^docs/evidence/usuario-$FASE-[0-9-]+\.md$"); then
    for f in $archivos; do
      contenido=$(en_repo show "$REF:$f" 2>/dev/null) || continue
      evidencia="$evidencia
$contenido"
    done
  fi
  det=$(FASE="$FASE" FILAS="$filas_fase" EVIDENCIA="$evidencia" timeout 30 python3 -c '
import os, re, sys

FASE = os.environ["FASE"]
filas = os.environ.get("FILAS", "")
evid = os.environ.get("EVIDENCIA", "")

# Solo la linea literal "Promesa: <...> — ruta: <...>." dentro de la fila cuenta
# como promesa observable. "Promesa: sin promesa observable." es una promesa
# declarada explicitamente como ausente, y no exige evidencia.
sin_promesa_re = re.compile(r"Promesa: sin promesa observable\.")
promesa_re = re.compile(r"Promesa: .+? — ruta: .+?\.")

prometidas = []
for linea in filas.splitlines():
    if not linea.strip():
        continue
    celdas = linea.split("|")
    if len(celdas) < 2:
        continue
    tid = celdas[1].strip()
    if not tid:
        continue
    if sin_promesa_re.search(linea):
        continue
    if promesa_re.search(linea):
        prometidas.append(tid)

if not prometidas:
    print("VERDE ninguna fila de la fase " + FASE + " declara promesa observable")
    raise SystemExit

# Bloques "## <tid>" de los archivos de evidencia, hasta el proximo encabezado.
bloques = {}
actual = None
for linea in evid.splitlines():
    m = re.match(r"^## (\S+)", linea)
    if m:
        actual = m.group(1)
        bloques.setdefault(actual, [])
        continue
    if actual is not None:
        bloques[actual].append(linea)

faltan = []
sin_funciona = []
for tid in prometidas:
    lineas_bloque = bloques.get(tid)
    if not lineas_bloque:
        faltan.append(tid)
        continue
    texto = "\n".join(lineas_bloque)
    m = re.search(r"^(FUNCIONA|NO FUNCIONA|NO PUDE PROBARLO)\b", texto, re.M)
    if not m or m.group(1) != "FUNCIONA":
        sin_funciona.append(tid)

if faltan or sin_funciona:
    partes = []
    if faltan:
        partes.append("sin evidencia: " + " ".join(sorted(faltan)))
    if sin_funciona:
        partes.append("sin FUNCIONA: " + " ".join(sorted(sin_funciona)))
    print("ROJO " + "; ".join(partes))
else:
    print("OK %d filas con promesa, todas FUNCIONA" % len(prometidas))
' || printf '%s' '""')
  case "$det" in
    "OK "*)    linea VERDE usuario "${det#OK }" ;;
    "VERDE "*) linea VERDE usuario "${det#VERDE }" ;;
    "ROJO "*)  linea ROJO usuario "${det#ROJO }" ;;
    *)         linea unknown usuario "no pude comprobar las promesas observables de la fase" ;;
  esac
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
