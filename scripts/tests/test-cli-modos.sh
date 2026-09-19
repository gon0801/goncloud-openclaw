#!/bin/bash
# 9.1 Contratos: validadores de corrida.v1 / seguimiento.v1 y cobertura de cli-modos.tsv.
# Los validadores viven en scripts/mac/corrida/lib.sh (criterio unico): esta prueba
# carga lib.sh y ejercita el mismo codigo que corre en produccion.
# Uso: bash scripts/tests/test-cli-modos.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

TMP=$(mktemp -d) || exit 1
# El trap vive junto al mktemp (arriba del todo) para cubrir tambien los fail
# tempranos. Borra solo los json creados (rm -f, no recursivo: regla del carril).
trap 'rm -f "$TMP"/*.json "$TMP"/*.txt 2>/dev/null' EXIT
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
for r in dura-rm-separado dura-rm-largos dura-rm-Rf dura-rm-r-fuerza dura-rm-R-sep; do
  revienta "$r" "lista dura aprobada"
done
validar_registro "$FX/registro-pasa-emergencia.json" || fail "emergencia dio lista dura (falso positivo)"
validar_registro "$FX/registro-pasa-dropbox.json" || fail "dropbox dio lista dura (falso positivo)"

# FB: campos exigidos — un registro sin cada uno de ellos cae con su motivo (los
# mutantes se generan al vuelo desde el valido). El || fail vela al generador: si
# muere, la prueba no puede seguir en verde (CodeRabbit IC).
python3 - "$TMP" "$FX" <<'PY' || fail "el generador de falta-* fallo"
import json,sys
tmp,fx=sys.argv[1],sys.argv[2]
d0=json.load(open(fx+'/registro-valido.json'))
for nom in ('cli_modos','cron_vigia_id','inicio','simulacro'):
  d=json.loads(json.dumps(d0)); d.pop(nom,None)
  json.dump(d,open('%s/falta-%s.json'%(tmp,nom),'w'),indent=1)
d=json.loads(json.dumps(d0)); d['canal'].pop('destino',None)
json.dump(d,open(tmp+'/falta-destino.json','w'),indent=1)
d=json.loads(json.dumps(d0)); d['preaprobaciones']=5
json.dump(d,open(tmp+'/falta-prea.json','w'),indent=1)
PY
revienta_archivo() { # $1 archivo, $2 motivo esperado
  out="$(validar_registro "$1" 2>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] || fail "registro incompleto pasa: $(basename "$1")"
  printf '%s' "$out" | grep -qF "ROTO:$2" || fail "$(basename "$1") sin su motivo ($2):
$out"
}
revienta_archivo "$TMP/falta-destino.json" "sin canal.destino"
revienta_archivo "$TMP/falta-cli_modos.json" "sin cli_modos"
revienta_archivo "$TMP/falta-cron_vigia_id.json" "sin cron_vigia_id"
revienta_archivo "$TMP/falta-inicio.json" "sin inicio"
revienta_archivo "$TMP/falta-simulacro.json" "simulacro no es booleano"
revienta_archivo "$TMP/falta-prea.json" "preaprobaciones no es lista"

# MATRIZ del detector de borrado recursivo (CA+CB+CE-r): todos los casos de una
# vez; la mutacion (sin la regla) debe ponerla entera en rojo. Nota: el caso
# "--force," de la matriz se codifica como "rm --recursive --force," — la regla
# exige recursividad (r); una -f sola jamas cuenta (CE-r). El || fail vela al
# generador: muerto el, el glob de la matriz queda literal y la matriz muda.
python3 - "$TMP" "$FX" <<'PY' || fail "el generador de la matriz fallo"
import json,sys
tmp,fx=sys.argv[1],sys.argv[2]
rojo=['rm -rf','rm -fr','rm -Rf','rm -R -f','rm -r -f','rm --recursive --force',
      'rm -vvvrf','`rm -rf`','"rm -rf"','rm -rf,','(rm -r -f)','rm --recursive --force,',
      'rm -r dir','borrado con rm ' + 'relleno inofensivo '*10 + 'y al final -r -f del area',
      'RM -RF','Rm -rf','rm --r build','rm --rec -f build','rm --forc -r']
limpio=['atencion en emergencia','respaldo en dropbox','quitar con rm -f y -restar horas',
        'solo restar horas','la fecha 18/09 quedo','esto y/o aquello','rm --resto cosas']
d0=json.load(open(fx+'/registro-valido.json'))
for lado,patrones in (('rojo',rojo),('limpio',limpio)):
  for i,p in enumerate(patrones):
    d=json.loads(json.dumps(d0))
    d['preaprobaciones']=[{'patron':p,'decision':'Aprobado'}]
    json.dump(d,open('%s/matriz-%s-%02d.json'%(tmp,lado,i),'w'),indent=1)
PY
for f in "$TMP"/matriz-rojo-*.json; do
  validar_registro "$f" >/dev/null 2>&1 \
    && fail "matriz: debia ser rojo: $(basename "$f")"
done
for f in "$TMP"/matriz-limpio-*.json; do
  validar_registro "$f" >/dev/null 2>&1 \
    || fail "matriz: debia pasar limpio: $(basename "$f")"
done

# runbook_de deriva la raiz del propio lib.sh (no del pwd): desde /tmp y sin
# REPO_DIR, un runbook relativo REAL resuelve igual, en forma fisica.
LIBABS="$PWD/scripts/mac/corrida/lib.sh"
RAIZFIS="$(CDPATH= cd -P -- . && pwd)"
z1="$( cd /tmp && env -u REPO_DIR bash -c ". '$LIBABS'; runbook_de scripts/tests/fixtures/corrida/runbook-simulacro.md" )"
[ "$z1" = "$RAIZFIS/scripts/tests/fixtures/corrida/runbook-simulacro.md" ] \
  || fail "runbook_de desde fuera del repo no resuelve contra la raiz del repo: $z1"
[ -f "$z1" ] || fail "la ruta que resolvio runbook_de no existe: $z1"

# mensaje_valido viene de lib.sh: es el que corre en cada envio de verdad.
mensaje_valido "$FX/mensaje-valido.txt" || fail "el mensaje valido no pasa"
# Los casos sin salto de linea final se generan al vuelo: un archivo del repo sin
# salto final lo reescribe el hook de end-of-file, y el caso es justo ese.
printf '[AVANZA] Fase 9, 2 de 5 partes terminadas\nQue cambio: la primera parte quedo lista\nQue sigue: ahora se trabaja la parte de mensajes\nQue necesito de ti: nada' >"$TMP/val-sin-salto.txt"
printf '[AVANZA] Fase 9, 2 de 5 partes terminadas\nQue cambio: la primera parte quedo lista\nQue sigue: ahora se trabaja la parte de mensajes\nQue necesito de ti: nada\nsobra' >"$TMP/cinco-sin-salto.txt"
mensaje_valido "$TMP/val-sin-salto.txt" || fail "4 lineas sin salto final no pasan"
mensaje_valido "$TMP/cinco-sin-salto.txt" 2>/dev/null && fail "5 lineas sin salto final pasan"
mensaje_valido "$FX/mensaje-etiqueta-mala.txt" 2>/dev/null && fail "etiqueta desconocida pasa"
mensaje_valido "$FX/mensaje-cerrada-pelada.txt" 2>/dev/null && fail "un [CERRADA] pelado pasa"
mensaje_valido "$FX/mensaje-forma-mala.txt" 2>/dev/null && fail "forma sin prefijos pasa"
mensaje_valido "$FX/mensaje-forma-sin-avance.txt" 2>/dev/null && fail "linea 1 sin avance pasa"
mensaje_valido "$FX/mensaje-linea-vacia.txt" 2>/dev/null && fail "prefijo con contenido vacio pasa"
mensaje_valido "$FX/mensaje-necesito-solo-comando.txt" 2>/dev/null && fail "NECESITO sin pregunta pasa"
for j in palabra ruta flag sha sha256 tilde commits mergeado prs mergear rama push rebase hash-mayus hash-mixto; do
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
