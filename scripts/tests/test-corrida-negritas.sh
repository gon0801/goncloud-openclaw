#!/bin/bash
# 14.12 negritas en los avisos de la corrida ("lo importante en negritas"):
# el avance de la linea 1 y el "Qué cambió" salen en **negrita** siempre; el
# "Qué necesito de ti" solo en NECESITO TU RESPUESTA (partiendo la negrita
# antes del segmento "Comando: "); "Qué sigue" es rutina y no lleva. Los
# validadores (mensaje_valido / jerga_en_texto) siguen aceptando el mensaje
# con y sin negritas. Sin tmux y sin red: OPENCLAW_BIN apunta a un stub que
# captura el texto de -m y emite ok. Uso: bash scripts/tests/test-corrida-negritas.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
texto_json() { # $1 linea de mensajes.jsonl -> su campo 'texto' decodificado
  printf '%s' "$1" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('texto',''))"
}

. scripts/mac/corrida/lib.sh

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/corridas/t9" "$T/corridas/t9r" "$T/bin"
export CORRIDA_STATE="$T/corridas"

printf '# Titulo de practica\n' >"$T/runbook.md"
cat >"$T/corridas/t9/registro.json" <<EOF
{"schema":"corrida.v2","id":"t9","estado":"abierta","inicio":"2026-09-27T10:00:00+0200","simulacro":true,"runbook":"$T/runbook.md","canal":{"destino":"DEST-9X"}}
EOF
cat >"$T/corridas/t9r/registro.json" <<EOF
{"schema":"corrida.v2","id":"t9r","estado":"abierta","inicio":"2026-09-27T10:00:00+0200","simulacro":false,"runbook":"$T/runbook.md","canal":{"destino":"DEST-9X"}}
EOF

# Stub openclaw: captura el ultimo argumento (el texto de -m) y emite ok.
cat >"$T/bin/openclaw" <<STUB
#!/bin/sh
last=""
for a do last="\$a"; done
printf '%s' "\$last" > "$T/captura.txt"
printf '{"ok":true,"messageId":7}'
STUB
chmod +x "$T/bin/openclaw"
export OPENCLAW_BIN="$T/bin/openclaw"

# (a) DETENIDA en practica: avance y cambio en negrita; sigue y necesito sin.
rc=0
corrida_mensaje t9 DETENIDA "1 de 2 partes terminadas" "hubo un percance" "se retoma" "nada" \
  2>"$T/a.err" || rc=$?
[ "$rc" -eq 0 ] || fail "(a) DETENIDA en practica fallo (rc=$rc): $(cat "$T/a.err")"
ultima="$(tail -n1 "$T/corridas/t9/mensajes.jsonl")"
printf '%s' "$ultima" | grep -q '"ok": true' || fail "(a) el envio no quedo ok: $ultima"
texto_json "$ultima" >"$T/a.txt"
grep -qxF '🧪 PRÁCTICA — no contestes 🔴 [DETENIDA] Titulo de practica (abrió 10:00), **1 de 2 partes terminadas**' "$T/a.txt" \
  || fail "(a) la linea 1 no trae el avance en negrita: $(cat "$T/a.txt")"
grep -qxF 'Qué cambió: **hubo un percance**' "$T/a.txt" \
  || fail "(a) el cambio no sale en negrita: $(cat "$T/a.txt")"
grep -qxF 'Qué sigue: se retoma' "$T/a.txt" \
  || fail "(a) 'Qué sigue' cambio: $(cat "$T/a.txt")"
sed -n 5p "$T/a.txt" | grep -qF '**' \
  && fail "(a) 'Qué sigue' es rutina y no lleva negrita: $(cat "$T/a.txt")"
grep -qxF 'Qué necesito de ti: nada' "$T/a.txt" \
  || fail "(a) la linea 4 cambio: $(cat "$T/a.txt")"
sed -n 7p "$T/a.txt" | grep -qF '**' \
  && fail "(a) con DETENIDA el necesito no lleva negrita: $(cat "$T/a.txt")"

# (b) NECESITO TU RESPUESTA real: el cambio fijado sale en negrita y la
# negrita de la linea 4 parte ANTES del segmento "Comando: ".
rc=0
corrida_mensaje t9r "NECESITO TU RESPUESTA" "1 de 2 partes terminadas" \
  "cambio del llamador" "sigue del llamador" \
  "Di sí para aceptar o no para rechazar. Comando: gh pr view 187" \
  2>"$T/b.err" || rc=$?
[ "$rc" -eq 0 ] || fail "(b) NECESITO real fallo (rc=$rc): $(cat "$T/b.err")"
grep -qxF 'Qué cambió: **Una parte de la corrida quedó esperando que decidas algo.**' "$T/captura.txt" \
  || fail "(b) el cambio fijado no sale en negrita: $(cat "$T/captura.txt")"
grep -qxF 'Qué necesito de ti: **Di sí para aceptar o no para rechazar.** Comando: gh pr view 187' "$T/captura.txt" \
  || fail "(b) la negrita de la linea 4 no parte antes de Comando: : $(cat "$T/captura.txt")"

# (c) ABIERTA sin avance: la linea 1 exacta y sin ninguna negrita.
corrida_mensaje t9 ABIERTA "" "cambio de apertura" "sigue de apertura" "nada" \
  2>"$T/c.err" || fail "(c) ABIERTA fallo: $(cat "$T/c.err")"
ultima="$(tail -n1 "$T/corridas/t9/mensajes.jsonl")"
texto_json "$ultima" >"$T/c.txt"
grep -qxF '🧪 PRÁCTICA — no contestes [ABIERTA] Titulo de practica (abrió 10:00)' "$T/c.txt" \
  || fail "(c) la linea 1 de ABIERTA no es la exacta: $(cat "$T/c.txt")"
sed -n 1p "$T/c.txt" | grep -qF '**' \
  && fail "(c) una linea 1 sin avance no lleva negrita: $(cat "$T/c.txt")"

# (d) el validador tolera ambas formas: el mismo texto v2 de 4 bloques sin
# negritas y con las negritas del contrato pasan mensaje_valido igual.
printf '🧪 PRÁCTICA — no contestes 🟢 [AVANZA] Titulo de practica (abrió 10:00), 2 de 5 partes terminadas\n\nQué cambió: quedo lista la parte de mensajes\n\nQué sigue: ahora se revisa\n\nQué necesito de ti: nada\n' >"$T/d-sin.txt"
printf '🧪 PRÁCTICA — no contestes 🟢 [AVANZA] Titulo de practica (abrió 10:00), **2 de 5 partes terminadas**\n\nQué cambió: **quedo lista la parte de mensajes**\n\nQué sigue: ahora se revisa\n\nQué necesito de ti: nada\n' >"$T/d-con.txt"
mensaje_valido "$T/d-sin.txt" || fail "(d) un mensaje v2 sin negritas dejo de ser valido"
mensaje_valido "$T/d-con.txt" || fail "(d) un mensaje v2 con las negritas del contrato no pasa el validador"

# (e) 14.27 R3: un cambio vacio sigue fuera de contrato (antes salia
# "Qué cambió: ****" y el validador lo daba por bueno) y no se manda nada.
antes="$(grep -c . "$T/corridas/t9/mensajes.jsonl")"
rc=0
corrida_mensaje t9 DETENIDA "1 de 2 partes terminadas" "" "se retoma" "nada" 2>"$T/e.err" || rc=$?
[ "$rc" -ne 0 ] || fail "(e) un cambio vacio salio como mensaje valido"
grep -q 'fuera de contrato' "$T/e.err" || fail "(e) el rechazo no dice fuera de contrato: $(cat "$T/e.err")"
[ "$(grep -c . "$T/corridas/t9/mensajes.jsonl")" = "$antes" ] || fail "(e) el cambio vacio llego a la cola de entrega"

# (f) 14.27 R3: NECESITO real con la pregunta vacia antes de "Comando: " no
# pasa por el relleno de la negrita.
rc=0
corrida_mensaje t9r "NECESITO TU RESPUESTA" "1 de 2 partes terminadas" "c" "s" " Comando: gh pr view 187" \
  2>"$T/f.err" || rc=$?
[ "$rc" -ne 0 ] || fail "(f) una pregunta vacia antes de Comando: salio como mensaje valido"

# (g) 14.27 R3: los ** que trae el llamador no se anidan dentro de la negrita.
corrida_mensaje t9 DETENIDA "1 de 2 partes terminadas" "hubo un **gran** percance" "se retoma" "nada" \
  2>"$T/g.err" || fail "(g) DETENIDA con ** del llamador fallo: $(cat "$T/g.err")"
texto_json "$(tail -n1 "$T/corridas/t9/mensajes.jsonl")" >"$T/g.txt"
grep -qxF 'Qué cambió: **hubo un gran percance**' "$T/g.txt" \
  || fail "(g) los ** del llamador quedaron anidados: $(cat "$T/g.txt")"

# (h) 19.3-3-F1: el camino directo fija el mismo texto de NECESITO que
# corrida_mensaje (seguimiento.v1: el texto es fijo, no lo decide el llamador).
rc=0
corrida_aviso_directo t9r "NECESITO TU RESPUESTA" "1 de 2 partes terminadas" \
  "cambio del llamador" "sigue del llamador" "pregunta del llamador" \
  2>"$T/h.err" || rc=$?
[ "$rc" -eq 0 ] || fail "(h) NECESITO directo fallo (rc=$rc): $(cat "$T/h.err")"
grep -qxF 'Qué cambió: **Una parte de la corrida quedó esperando que decidas algo.**' "$T/captura.txt" \
  || fail "(h) el directo no fijo la linea 2: $(cat "$T/captura.txt")"
rc=0
corrida_aviso_directo t9 "NECESITO TU RESPUESTA" "1 de 2 partes terminadas" \
  "cambio del llamador" "sigue del llamador" "pregunta del llamador" \
  2>"$T/h2.err" || rc=$?
[ "$rc" -eq 0 ] || fail "(h) NECESITO directo en practica fallo (rc=$rc): $(cat "$T/h2.err")"
grep -qxF 'Qué cambió: **Una parte de la prueba llegó a una pregunta de práctica.**' "$T/captura.txt" \
  || fail "(h) el directo no fijo la linea 2 de practica: $(cat "$T/captura.txt")"
grep -qxF 'Qué necesito de ti: **nada: es una prueba, se resuelve sola**' "$T/captura.txt" \
  || fail "(h) el directo no fijo la linea 4 de practica: $(cat "$T/captura.txt")"
echo "ok (h): el directo fija el texto de NECESITO"

echo "TODO VERDE: test-corrida-negritas"
