#!/bin/bash
# 9.1 Contratos: validadores de corrida.v1 / seguimiento.v1 y cobertura de cli-modos.tsv.
# Los validadores viven en scripts/mac/corrida/lib.sh (criterio unico): esta prueba
# carga lib.sh y ejercita el mismo codigo que corre en produccion.
# Uso: bash scripts/tests/test-cli-modos.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

FX=scripts/tests/fixtures/corrida
TSV=scripts/mac/cli-modos.tsv
ZSH=scripts/mac/agent-tmux-shell.zsh
. scripts/mac/corrida/lib.sh

# --- casos ---
[ -f "$TSV" ] || fail "falta $TSV"
validar_registro "$FX/registro-valido.json" || fail "el registro valido no pasa"
# Cada mutante cae Y cita su motivo: el rechazo mudo no dice nada a quien abrio mal.
revienta() { # $1 sufijo del fixture, $2 motivo esperado
  out="$(validar_registro "$FX/registro-$1.json" 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] || fail "registro mutante pasa: $1"
  printf '%s' "$out" | grep -qF "ROTO:$2" || fail "$1 no cita su motivo ($2):
$out"
}
revienta vigia-malo "vigia fuera del conjunto"
revienta sesion-sin-rol "sesion sin rol"
revienta schema-malo "schema distinto"
revienta sin-canal "sin canal.cron"
revienta estado-malo "estado fuera del conjunto"
revienta timebox-malo "timebox no numerico"
revienta timebox-cero "timebox fuera de rango"
revienta sesion-sin-dir "sesion sin dir"
revienta decision-mala "decision fuera del conjunto"
revienta lista-dura "lista dura aprobada"
# Lista dura por regex con bordes: las variantes caen, los inocentes pasan.
revienta dura-rmrf "lista dura aprobada"
revienta dura-forcepush "lista dura aprobada"
revienta dura-rm-separado "lista dura aprobada"
validar_registro "$FX/registro-pasa-emergencia.json" || fail "emergencia dio lista dura (falso positivo)"
validar_registro "$FX/registro-pasa-dropbox.json" || fail "dropbox dio lista dura (falso positivo)"

# runbook_de sin REPO_DIR y desde un subdirectorio resuelve contra la raiz del repo
# (el contexto de launchd/latido no hereda REPO_DIR ni arranca en la raiz).
LIBABS="$PWD/scripts/mac/corrida/lib.sh"
z1="$( cd scripts/mac && env -u REPO_DIR bash -c ". '$LIBABS'; runbook_de tests/fixtures/corrida/runbook-simulacro.md" )"
[ "$z1" = "$PWD/tests/fixtures/corrida/runbook-simulacro.md" ] \
  || fail "runbook_de desde un subdirectorio no resuelve contra la raiz del repo: $z1"

# mensaje_valido viene de lib.sh: es el que corre en cada envio de verdad.
mensaje_valido "$FX/mensaje-valido.txt" || fail "el mensaje valido no pasa"
# Los casos sin salto de linea final se generan al vuelo: un archivo del repo sin
# salto final lo reescribe el hook de end-of-file, y el caso es justo ese.
TMP=$(mktemp -d) || exit 1
printf '[AVANZA] Fase 9, 2 de 5 partes terminadas\nQue cambio: la primera parte quedo lista\nQue sigue: ahora se trabaja la parte de mensajes\nQue necesito de ti: nada' >"$TMP/val-sin-salto.txt"
printf '[AVANZA] Fase 9, 2 de 5 partes terminadas\nQue cambio: la primera parte quedo lista\nQue sigue: ahora se trabaja la parte de mensajes\nQue necesito de ti: nada\nsobra' >"$TMP/cinco-sin-salto.txt"
mensaje_valido "$TMP/val-sin-salto.txt" || fail "4 lineas sin salto final no pasan"
mensaje_valido "$TMP/cinco-sin-salto.txt" 2>/dev/null && fail "5 lineas sin salto final pasan"
mensaje_valido "$FX/mensaje-etiqueta-mala.txt" 2>/dev/null && fail "etiqueta desconocida pasa"
mensaje_valido "$FX/mensaje-forma-mala.txt" 2>/dev/null && fail "forma sin prefijos pasa"
mensaje_valido "$FX/mensaje-forma-sin-avance.txt" 2>/dev/null && fail "linea 1 sin avance pasa"
mensaje_valido "$FX/mensaje-linea-vacia.txt" 2>/dev/null && fail "prefijo con contenido vacio pasa"
mensaje_valido "$FX/mensaje-necesito-solo-comando.txt" 2>/dev/null && fail "NECESITO sin pregunta pasa"
for j in palabra ruta flag sha tilde commits mergeado prs mergear rama push rebase hash-mayus hash-mixto; do
  mensaje_valido "$FX/mensaje-jerga-$j.txt" 2>/dev/null && fail "jerga ($j) pasa"
done
# Falsos positivos declarados residuales: sin digito o sin letra no es sha.
mensaje_valido "$FX/mensaje-pasa-acabada.txt" || fail "acabada (solo letras) dio jerga"
mensaje_valido "$FX/mensaje-pasa-numeros.txt" || fail "1234567 (solo digitos) dio jerga"
# El marcador "Comando: ": uno, al final de la linea 4, solo en NECESITO TU RESPUESTA.
mensaje_valido "$FX/mensaje-comando-valido.txt" || fail "el comando textual en NECESITO no pasa"
mensaje_valido "$FX/mensaje-comando-sin-necesito.txt" 2>/dev/null && fail "Comando fuera de NECESITO pasa"
mensaje_valido "$FX/mensaje-comando-doble.txt" 2>/dev/null && fail "dos Comando pasan"
mensaje_valido "$FX/mensaje-comando-en-linea-2.txt" 2>/dev/null && fail "Comando en las lineas 1-3 pasa"
mensaje_valido "$FX/mensaje-comando-largo.txt" 2>/dev/null && fail "un Comando de mas de 200 pasa"

# Cobertura: cada CLI de AGENT_TMUX_TOOLS tiene fila en cli-modos.tsv.
clis=$(grep -E '^AGENT_TMUX_TOOLS=\(' "$ZSH" | sed 's/.*(\(.*\)).*/\1/')
[ -n "$clis" ] || fail "no se pudo leer AGENT_TMUX_TOOLS de $ZSH"
for c in $clis; do
  grep -qE "^${c}	" "$TSV" || fail "$TSV: sin fila para $c"
done

echo "TODO VERDE: test-cli-modos"
