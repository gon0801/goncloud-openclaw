#!/bin/bash
# clasificar-cambio.sh -- selecciona el carril de CI (fast | completo) POR ARCHIVOS.
# Fase 15.0, carril S. La politica completa vive en Plans.md ("Politica de
# seleccion aprobada"); esto es su implementacion. El contrato:
#
# Uso:
#   bash scripts/clasificar-cambio.sh --base <ref> --head <ref> [--allowlist <ruta>]
#
#   --base       extremo base del rango. En un PR, la rama base (el script la
#                reduce al merge-base: "todos los cambios desde la base comun
#                hasta el head"). En un push, el `before` del evento, que es
#                ancestro del `after` y por lo tanto su propia base comun.
#   --head       extremo nuevo: head del PR o `after` del push.
#   --allowlist  allowlist fast (default: ci-fast-allowlist.txt junto a este
#                script; en CI siempre se usa la versionada del repo).
#
# Salida:
#   stdout        UNA linea: `fast` o `completo`. Es el contrato visible.
#   stderr        diagnostico humano: rango, cantidad de archivos, motivo.
#   GITHUB_OUTPUT si esta definido, agrega `carril=<fast|completo>` y
#                 `motivo=<una linea>`; .github/workflows/quality.yml los
#                 expone como outputs del job clasificador.
#
# Exit:
#   0  clasifico. `fast` y `completo` son veredictos validos, y TODO caso
#      fail-closed (base/head inresoluble, historial incompleto, merge-base
#      imposible, diff que falla, estado de diff no soportado, linea con forma
#      inesperada, ruta fuera de contrato) tambien es exit 0 con veredicto
#      `completo`: es una seleccion, no un error.
#   2  error de uso o de herramienta (args, allowlist ilegible, no es un repo
#      git). Sin veredicto: el job del workflow muere rojo y el gate no
#      autoriza ninguna omision. El fail-closed de "la clasificacion no
#      existe" vive en el gate, no aca.
#
# Reglas de la politica que este script garantiza:
#   - clasifica POR ARCHIVOS contra la allowlist versionada; nunca por titulo,
#     etiqueta o declaracion. La extension .md por si sola no es fast: hay
#     documentos que controlan comportamiento y no estan enumerados.
#   - la llave no abre su propia puerta: tocar scripts/ci-fast-allowlist.txt,
#     scripts/clasificar-cambio.sh o .github/workflows/quality.yml clasifica
#     completo SIN consultar la allowlist (el mismo cambio que reescribe la
#     llave no puede usarla para abrirse la puerta del fast). La ruta del
#     workflow la marca este script por nombre, no leyendolo: es config de CI.
#   - renombres: origen Y destino deben ser fast para que el cambio sea fast.
#   - symlinks, gitlinks (submodulos) y cualquier modo no regular son
#     completo: en --name-status se ven como A/T y la allowlist no mira modos.
#   - los borrados cuentan (un D sobre una ruta fuera de contrato es completo).
#   - un cambio sin archivos (base == head) es fast: no hay nada que probar;
#     "no pude comparar" es otro caso y SI es completo.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 2
USO="uso: bash scripts/clasificar-cambio.sh --base <ref> --head <ref> [--allowlist <ruta>]"

BASE_REF=
HEAD_REF=
ALLOWLIST=
while [ $# -gt 0 ]; do
  case $1 in
    --base|--head|--allowlist)
      [ $# -ge 2 ] || { printf '%s\n%s\n' "argumento incompleto: $1" "$USO" >&2; exit 2; }
      case $1 in
        --base)      BASE_REF=$2 ;;
        --head)      HEAD_REF=$2 ;;
        --allowlist) ALLOWLIST=$2 ;;
      esac
      shift 2 ;;
    -h|--help) printf '%s\n' "$USO"; exit 0 ;;
    *) printf '%s\n%s\n' "argumento desconocido: $1" "$USO" >&2; exit 2 ;;
  esac
done
[ -n "$BASE_REF" ] && [ -n "$HEAD_REF" ] || {
  printf '%s\n%s\n' "hace falta --base y --head" "$USO" >&2; exit 2;
}
: "${ALLOWLIST:=$SCRIPT_DIR/ci-fast-allowlist.txt}"
# F3 (auditoria adversarial post-Fase 15): archivo REGULAR y legible. Un -r
# suelto era cierto para un directorio, la barrera no cortaba y el script
# moria despues ADENTRO con exit 1 sin veredicto; el contrato de la cabecera
# promete exit 2 aca, el error de herramienta que deja el job rojo.
[ -f "$ALLOWLIST" ] && [ -r "$ALLOWLIST" ] || { echo "FAIL: no se puede leer la allowlist: $ALLOWLIST" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "FAIL: no estoy dentro de un repo git (corre desde el clon que se clasifica)" >&2; exit 2;
}

patron_a_regex() {
  # Traduce un patron de la allowlist a regex POSIX extendida:
  #   **/  cualquier profundidad de directorios, INCLUIDA cero (gitignore-style)
  #   **   cualquier cosa, cruzando '/'
  #   *    cualquier cosa que NO cruce '/'
  #   ?    un caracter que no es '/'
  # Todo lo demas es literal (los metacaracteres de regex van escapados).
  local p=$1 out='' i c sig
  for ((i = 0; i < ${#p}; i++)); do
    c=${p:i:1}
    case $c in
      '*')
        sig=${p:i+1:1}
        if [ "$sig" = '*' ]; then
          sig=${p:i+2:1}
          if [ "$sig" = '/' ]; then
            out+='([^/]+/)*'   # consume los 3 caracteres de '**/'
            i=$((i + 2))
          else
            out+='.*'          # '**' suelto: consume 2 caracteres
            i=$((i + 1))
          fi
        else
          out+='[^/]*'         # '*' no cruza '/'
        fi ;;
      '?') out+='[^/]' ;;
      .\[\\\^\$\(\)\+\{\|) out+="\\$c" ;;
      *) out+=$c ;;
    esac
  done
  printf '%s' "$out"
}

patron_casa() { # <ruta> <patron>: 0 si la ruta casa con el patron completo
  local ruta=$1 patron=$2 re
  re=$(patron_a_regex "$patron")
  [[ $ruta =~ ^$re$ ]]
}

ruta_es_fast() { # <ruta>: 0 si ALGUNA regla de la allowlist casa con la ruta
  local ruta=$1 patron
  while IFS= read -r patron || [ -n "$patron" ]; do
    patron=${patron#${patron%%[![:space:]]*}}   # sangria inicial
    patron=${patron%${patron##*[![:space:]]}}   # espacio final
    case $patron in ''|'#'*) continue ;; esac
    patron_casa "$ruta" "$patron" && return 0
  done < "$ALLOWLIST"
  return 1
}

# Archivos que controlan la clasificacion misma (la llave y sus cerraduras).
# Cualquier cambio que los toca clasifica completo ANTES de consultar la
# allowlist: ese mismo cambio pudo reescribirla (p.ej. a '**'), y la llave no
# puede autorizar la puerta del fast en el mismo cambio que la cambia.
ruta_es_control() { # <ruta>: 0 si la ruta controla la clasificacion
  case $1 in
    scripts/ci-fast-allowlist.txt|scripts/clasificar-cambio.sh|.github/workflows/quality.yml) return 0 ;;
  esac
  return 1
}

# Symlinks (120000), gitlinks (160000) y modos desconocidos JAMAS son fast:
# `git diff --name-status` no muestra modos y un symlink nuevo en ruta
# allowlisted se veria como 'A' indistinguible de un .md. 000000 = ese extremo
# no existe (alta o baja).
modo_es_regular() { # <modo>: 0 si es archivo regular (100644/100755)
  case $1 in
    100644|100755) return 0 ;;
  esac
  return 1
}
modos_sanos() { # <modo_origen> <modo_destino>: 0 si todo extremo existente es archivo regular
  [ "$1" = 000000 ] || modo_es_regular "$1" || return 1
  [ "$2" = 000000 ] || modo_es_regular "$2" || return 1
  return 0
}

veredicto() { # <fast|completo> <motivo de una linea>
  printf '%s\n' "$1"
  printf 'clasificar-cambio: carril=%s\nclasificar-cambio: motivo=%s\n' "$1" "$2" >&2
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    # Si la escritura falla, el workflow queda SIN output de este paso: la
    # bateria corre (la condicion del job es "!= fast") y el gate rebota la
    # omision. Fallar aca seria lo mismo pero mas ruidoso.
    { printf 'carril=%s\n' "$1"; printf 'motivo=%s\n' "$2"; } >> "$GITHUB_OUTPUT" 2>/dev/null || true
  fi
  exit 0
}

# --- rango: base comun .. head ----------------------------------------------
BASE_SHA=$(git rev-parse --verify --quiet "$BASE_REF^{commit}" 2>/dev/null) || {
  veredicto completo "base inresoluble ($BASE_REF): historial incompleto o ref invalida"
}
HEAD_SHA=$(git rev-parse --verify --quiet "$HEAD_REF^{commit}" 2>/dev/null) || {
  veredicto completo "head inresoluble ($HEAD_REF)"
}
MB=$(git merge-base "$BASE_SHA" "$HEAD_SHA" 2>/dev/null) || {
  veredicto completo "merge-base($BASE_REF, $HEAD_REF) fallo: historial incompleto o historias sin ancestor comun"
}
[ -n "$MB" ] || veredicto completo "merge-base vacio"

if ! LISTA=$(git -c core.quotepath=false diff --raw --find-renames "$MB" "$HEAD_SHA" 2>/dev/null); then
  veredicto completo "git diff fallo en ${MB:0:12}..${HEAD_SHA:0:12} (comparacion fallida)"
fi

# --- clasificacion archivo por archivo ---------------------------------------
# Formato --raw: ':<modo_origen> <modo_destino> <sha_o> <sha_d> <estado>\t<ruta>'
# (los renombres traen dos rutas y estado R*/C*; el rename detection va FORZADO
# con --find-renames para no depender de la config local). Los modos viajan EN
# la linea: la politica manda symlink, gitlink o modo desconocido a completo y
# --name-status no los muestra. Cualquier otra cosa (estado raro, cantidad de
# campos inesperada por una ruta con tabulador) rebota a completo: si no puedo
# asegurar el archivo, no lo clasifico.
total=0
fuera=0
motivo=
while IFS= read -r linea; do
  [ -n "$linea" ] || continue
  total=$((total + 1))
  cabecera=${linea%%$'\t'*}
  rutas=${linea#*$'\t'}
  campos=1
  restante=$rutas
  while [[ $restante == *$'\t'* ]]; do
    restante=${restante#*$'\t'}
    campos=$((campos + 1))
  done
  cabecera=${cabecera#:}
  modo_origen=${cabecera%% *}; cabecera=${cabecera#* }
  modo_destino=${cabecera%% *}; cabecera=${cabecera#* }
  estado=${cabecera##* }
  case $estado in
    A|M|D|T)
      if [ "$campos" -ne 1 ]; then
        fuera=$((fuera + 1)); motivo="${motivo:+$motivo }linea de diff con forma inesperada"
        continue
      fi
      ruta=$rutas
      if ! modos_sanos "$modo_origen" "$modo_destino"; then
        fuera=$((fuera + 1))
        [ "$fuera" -le 5 ] && motivo="${motivo:+$motivo }modo no regular en $ruta (symlink/gitlink/desconocido)"
        continue
      fi
      if ruta_es_control "$ruta"; then
        veredicto completo "toca un archivo que controla la clasificacion: $ruta"
      fi
      if ! ruta_es_fast "$ruta"; then
        fuera=$((fuera + 1))
        [ "$fuera" -le 5 ] && motivo="${motivo:+$motivo }$ruta"
      fi ;;
    R*|C*)
      if [ "$campos" -ne 2 ]; then
        fuera=$((fuera + 1)); motivo="${motivo:+$motivo }linea de diff con forma inesperada (renombre)"
        continue
      fi
      origen=${rutas%%$'\t'*}
      destino=${rutas#*$'\t'}
      if ! modos_sanos "$modo_origen" "$modo_destino"; then
        fuera=$((fuera + 1))
        [ "$fuera" -le 5 ] && motivo="${motivo:+$motivo }modo no regular en renombre $origen -> $destino (symlink/gitlink/desconocido)"
        continue
      fi
      # La regla de archivos de control tambien aplica a cada extremo del
      # renombre: entrar o salir de la llave es tocar la llave.
      if ruta_es_control "$origen" || ruta_es_control "$destino"; then
        veredicto completo "toca un archivo que controla la clasificacion (renombre: $origen -> $destino)"
      fi
      # Renombre: origen Y destino deben ser fast; cada extremo cuenta.
      if ! ruta_es_fast "$origen"; then
        fuera=$((fuera + 1))
        [ "$fuera" -le 5 ] && motivo="${motivo:+$motivo }$origen (origen del renombre)"
      fi
      if ! ruta_es_fast "$destino"; then
        fuera=$((fuera + 1))
        [ "$fuera" -le 5 ] && motivo="${motivo:+$motivo }$destino (destino del renombre)"
      fi ;;
    *)
      fuera=$((fuera + 1)); motivo="${motivo:+$motivo }estado de diff no soportado: $estado" ;;
  esac
done < <(printf '%s\n' "$LISTA")

printf 'clasificar-cambio: rango %s..%s, %d archivo(s), allowlist %s\n' \
  "${MB:0:12}" "${HEAD_SHA:0:12}" "$total" "$ALLOWLIST" >&2

if [ "$fuera" -gt 5 ]; then
  motivo="$motivo (+$((fuera - 5)) mas)"
fi
if [ "$fuera" -eq 0 ]; then
  if [ "$total" -eq 0 ]; then
    veredicto fast "sin cambios entre la base comun y el head: nada que probar"
  fi
  veredicto fast "los $total archivo(s) del cambio estan en la allowlist"
fi
veredicto completo "fuera de contrato o inasegurable: $motivo"
