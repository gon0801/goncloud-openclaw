#!/bin/bash
# Prueba de scripts/reconciliar-progreso.sh: alinear el progreso local con GitHub.
#
# El caso real (Fase 9, 2026-09-20): los PR 97 y 98 ya estaban MERGED en GitHub y el
# progreso local los tenia detenidos por "esperando sello". El lead podia quedar
# parado por una causa obsoleta, porque nadie consultaba el estado del PR. La
# reconciliacion hace exactamente eso y nada mas: los carriles cuyo motivo nombra el
# sello y cuyo PR GitHub dice MERGED pasan a mergeado y se limpia SOLO ese motivo
# (detenido_por); los carriles sin ese motivo, sin PR o con otro estado no se tocan;
# cierre.at jamas se escribe; y si GitHub no contesta, el dato queda unknown sin
# cambiar nada. El script no manda mensajes: si la firma del parte cambia, el aviso
# lo manda el latido que ya existe (9.5), una sola vez.
#
# Todo corre con gh de mentira y reloj inyectado. Nunca se toca GitHub ni un perfil.
#
# Uso: bash scripts/tests/test-reconciliar-progreso.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

S=scripts/reconciliar-progreso.sh
[ -f "$S" ] || fail "falta $S"
/bin/bash -n "$S" || fail "$S no parsea con /bin/bash 3.2"
echo "ok (1): el script existe y parsea"

T=$(mktemp -d) || exit 1
NOW=1789999200   # 2026-09-22T02:00:00Z; los timestamps quedan deterministas

# gh de mentira: 97 y 98 responden segun su variable (MERGED por defecto), cualquier
# otro PR responde OPEN, y GH_CAIDO=1 simula GitHub caido (sale 1 sin escribir nada).
mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'STUB'
#!/bin/sh
n=""; prev=""
for a in "$@"; do [ "$prev" = "view" ] && n="$a"; prev="$a"; done
[ "${GH_CAIDO:-0}" = "1" ] && exit 1
[ "$n" = "98" ] && [ "${GH_98_CAIDO:-0}" = "1" ] && exit 1
case "$n" in
  97) printf '{"state": "%s"}\n' "${GH_97:-MERGED}";;
  98) printf '{"state": "%s"}\n' "${GH_98:-MERGED}";;
  *)  printf '{"state": "OPEN"}\n';;
esac
STUB
chmod +x "$T/bin/gh"

progreso() { # $1 destino: la Fase 9 congelada en el caso real
  cat >"$1" <<'DOC'
{
 "schema": "runbook-progress.v1",
 "runbook": "docs/runbooks/autopilot-fase9.md",
 "fase": "9",
 "titulo": "Cierre de Fase 9",
 "lead": {"agente": "glm", "inicio": "2026-09-20T12:00:00Z", "actualizado": "2026-09-20T12:40:00Z"},
 "atencion_requerida": {"necesaria": false, "motivo": null, "desde": null},
 "siguiente_paso": "esperando sello de 97 y 98",
 "carriles": [
  {"id": "M", "nombre": "Mensajes", "repo": "gon0801/goncloud-openclaw", "rama": "fase9/mensajes", "tareas": ["9.4"], "estado": "en-cola", "paso_loop": 7, "pr": 97, "head": "abc0797", "approve_lead": "abc0797", "ci": "verde", "coderabbit": "limpio", "residuales": [], "detenido_por": "esperando sello del kit", "ultimo_evento": null},
  {"id": "N", "nombre": "Nucleo", "repo": "gon0801/goncloud-openclaw", "rama": "fase9/nucleo", "tareas": ["9.2"], "estado": "atorado", "paso_loop": 7, "pr": 98, "head": "abc0998", "approve_lead": "abc0998", "ci": "verde", "coderabbit": "limpio", "residuales": [], "detenido_por": "esperando sello", "ultimo_evento": null},
  {"id": "D", "nombre": "Docs", "repo": "gon0801/goncloud-openclaw", "rama": "fase9/docs", "tareas": ["9.7", "9.13"], "estado": "pendiente", "paso_loop": 0, "pr": 100, "head": null, "approve_lead": null, "ci": "pendiente", "coderabbit": "pendiente", "residuales": [], "detenido_por": null, "ultimo_evento": null},
  {"id": "I", "nombre": "Instalacion", "repo": "gon0801/goncloud-openclaw", "rama": "fase9/instalacion", "tareas": ["9.10"], "estado": "pendiente", "paso_loop": 0, "pr": null, "head": null, "approve_lead": null, "ci": "pendiente", "coderabbit": "pendiente", "residuales": [], "detenido_por": null, "ultimo_evento": null},
  {"id": "S", "nombre": "Simulacro", "repo": "gon0801/goncloud-openclaw", "rama": "sin-rama", "tareas": ["9.0", "9.9"], "estado": "pendiente", "paso_loop": 0, "pr": null, "head": null, "approve_lead": null, "ci": "pendiente", "coderabbit": "pendiente", "residuales": [], "detenido_por": null, "ultimo_evento": null}
 ],
 "cola": [{"id": "Q0", "prs": [], "estado": "pendiente", "ventana": null, "merge_commits": [], "verificado": null, "detenido_por": null}],
 "eventos": [],
 "cierre": {"at": null, "telegram_message_id": null, "resumen": null}
}
DOC
}

corre() { CORR_AHORA="$NOW" GH_BIN="$T/bin/gh" bash "$S" "$@"; }

carril() { # $1 archivo, $2 id, $3 campo -> valor plano (null si es None)
  F="$1" CID="$2" CAMP="$3" python3 -c "
import json, os
d = json.load(open(os.environ['F']))
for c in d.get('carriles', []):
    if c.get('id') == os.environ['CID']:
        v = c.get(os.environ['CAMP'])
        print('null' if v is None else v)
        raise SystemExit
print('SIN-CARRIL')"
}

solo_eso() { # $1 original, $2 resultado, $3... ids tocados: todo igual salvo
             # estado/detenido_por de esos ids, eventos y lead.actualizado
  ORIG="$1" NUEVO="$2" TOCADOS="$3" python3 -c "
import json, os
a = json.load(open(os.environ['ORIG']))
b = json.load(open(os.environ['NUEVO']))
toc = os.environ['TOCADOS'].split()
assert a['schema'] == b['schema'], 'schema cambio'
assert a['fase'] == b['fase'], 'fase cambio'
assert a['siguiente_paso'] == b['siguiente_paso'], 'siguiente_paso cambio'
assert a['atencion_requerida'] == b['atencion_requerida'], 'atencion_requerida cambio'
assert a['cola'] == b['cola'], 'la cola cambio'
assert a['cierre'] == b['cierre'], 'cierre cambio: ' + repr(b['cierre'])
assert a['lead']['inicio'] == b['lead']['inicio'], 'lead.inicio cambio'
for ca, cb in zip(a['carriles'], b['carriles']):
    assert ca['id'] == cb['id'], 'los carriles cambiaron de orden'
    permitidos = {'estado', 'detenido_por'} if ca['id'] in toc else set()
    ka = {k: v for k, v in ca.items() if k not in permitidos}
    kb = {k: v for k, v in cb.items() if k not in permitidos}
    assert ka == kb, 'el carril %s cambio de mas: %s' % (ca['id'], sorted(set(ka.items()) ^ set(kb.items())))
print('ok')"
}

# (2) El caso de la Fase 9: 97 y 98 MERGED en GitHub, detenidos por el sello en el
# progreso. Quedan mergeado, se limpia SOLO ese motivo, y D, I y S siguen pendiente.
P="$T/progress.json"; progreso "$P"; cp "$P" "$P.original"
out=$(corre "$P"); rc=$?
[ "$rc" -eq 0 ] || fail "(2) la reconciliacion debe salir 0; salio $rc:
$out"
[ "$(carril "$P" M estado)" = "mergeado" ] || fail "(2) el carril M (pr 97) no quedo mergeado:
$out"
[ "$(carril "$P" N estado)" = "mergeado" ] || fail "(2) el carril N (pr 98) no quedo mergeado:
$out"
[ "$(carril "$P" M detenido_por)" = "null" ] || fail "(2) el motivo de M no se limpio"
[ "$(carril "$P" N detenido_por)" = "null" ] || fail "(2) el motivo de N no se limpio"
for c in D I S; do
  [ "$(carril "$P" "$c" estado)" = "pendiente" ] \
    || fail "(2) el carril $c no debe tocarce: quedo $(carril "$P" "$c" estado)"
  [ "$(carril "$P" "$c" detenido_por)" = "null" ] \
    || fail "(2) el carril $c perdio su detenido_por"
done
printf '%s' "$out" | grep -q 97 || fail "(2) la salida debe nombrar el pr 97:
$out"
printf '%s' "$out" | grep -q 98 || fail "(2) la salida debe nombrar el pr 98:
$out"
[ "$(solo_eso "$P.original" "$P" "M N")" = "ok" ] \
  || fail "(2) la reconciliacion toco campos de mas (ver arriba)"
nevt=$(F="$P" python3 -c "
import json, os
print(len(json.load(open(os.environ['F']))['eventos']))")
[ "$nevt" -eq 2 ] || fail "(2) esperaba un evento por carril reconciliado (2), hubo $nevt"
echo "ok (2): 97 y 98 pasan a mergeado, se limpia solo ese motivo y el resto no se toca"

# (3) Idempotente: correrla otra vez produce el mismo progreso y no hace nada.
cp "$P" "$P.tras-primera"
out=$(corre "$P"); rc=$?
[ "$rc" -eq 0 ] || fail "(3) la segunda pasada debe salir 0; salio $rc:
$out"
printf '%s' "$out" | grep -q "sin cambios" \
  || fail "(3) la segunda pasada debe declarar sin cambios:
$out"
cmp -s "$P" "$P.tras-primera" \
  || fail "(3) la segunda pasada modifico el progreso: no es idempotente"
echo "ok (3): la segunda pasada no cambia nada y lo declara"

# (4) La firma del parte (P_FIRMA de estado.sh, la que mira el latido para mandar)
# cambia SOLO con la primera reconciliacion; la segunda la deja quieta: sin mensaje
# repetido. Se calcula con parte_calcular de verdad, sobre un espejo de la corrida.
mkdir -p "$T/corridas/rec" "$T/repo" "$T/watch"
cat >"$T/corridas/rec/registro.json" <<'REG'
{"schema": "corrida.v2", "id": "rec", "runbook": "docs/runbooks/autopilot-fase9.md",
 "vigia": "claw", "simulacro": false, "seguimiento_global": true,
 "canal": {"cron": "verif-sync-repos", "destino": "DESTINO-FICTICIO-REC"},
 "cli_modos": "scripts/mac/cli-modos.tsv", "inicio": "2026-09-20T12:00:00+0000",
 "timebox_horas": 6, "sesiones": [], "preaprobaciones": [], "estado": "abierta"}
REG
cat >"$T/bin/tmux-falso" <<'STUB'
#!/bin/sh
exit 1
STUB
cat >"$T/bin/gh-falso" <<'STUB'
#!/bin/sh
case "$*" in
  *"pr list"*) printf '[]\n';;
esac
exit 0
STUB
chmod +x "$T/bin/tmux-falso" "$T/bin/gh-falso"
firma() { # $1 progress.json para el espejo -> P_FIRMA que calcularia el latido
  cp "$1" "$T/corridas/rec/progress.json"
  ( export CORRIDA_STATE="$T/corridas" WATCH_STATE_DIR="$T/watch" \
           TMUX_BIN="$T/bin/tmux-falso" GH_BIN="$T/bin/gh-falso" REPO_DIR="$T/repo"
    . scripts/mac/corrida/lib.sh
    . scripts/mac/corrida/estado.sh
    parte_calcular rec >/dev/null 2>&1 || { echo "ROTO"; exit 0; }
    printf '%s' "$P_FIRMA" )
}
f0=$(firma "$P.original")
f1=$(firma "$P.tras-primera")
[ "$f0" != "ROTO" ] || fail "(4) parte_calcular rechazo el registro o el espejo del fixture"
[ "$f1" != "ROTO" ] || fail "(4) parte_calcular rechazo el progreso reconciliado"
[ "$f0" != "$f1" ] \
  || fail "(4) la firma no cambio con la primera reconciliacion: el latido no avisaria el cambio"
f2=$(firma "$P")
[ "$f2" = "$f1" ] \
  || fail "(4) la segunda pasada cambio la firma: mandaria otro mensaje"
echo "ok (4): la firma del parte cambia una vez con el cambio real y queda quieta al repetir"

# (5) GitHub caido: el dato queda unknown, el archivo no se toca y la fase no se cierra.
P2="$T/caido.json"; progreso "$P2"; cp "$P2" "$P2.original"
out=$(GH_CAIDO=1 corre "$P2"); rc=$?
[ "$rc" -eq 3 ] || fail "(5) con GitHub caido debe salir 3 (unknown); salio $rc:
$out"
cmp -s "$P2" "$P2.original" \
  || fail "(5) con GitHub caido el progreso no debe cambiar"
printf '%s' "$out" | grep -qi unknown || fail "(5) la salida debe declarar unknown:
$out"
[ "$(python3 -c "import json;print(json.load(open('$P2'))['cierre']['at'])")" = "None" ] \
  || fail "(5) la fase quedo marcada cerrada con el dato unknown"
echo "ok (5): GitHub caido deja unknown, el archivo quieto y el cierre vacio"

# (6) Parcial: un PR contesta y el otro no. El que contesto se reconcilia; el que no,
# queda exactamente como estaba, y la corrida declara el unknown (rc 3).
P3="$T/parcial.json"; progreso "$P3"
out=$(GH_98_CAIDO=1 corre "$P3"); rc=$?
[ "$rc" -eq 3 ] || fail "(6) con una consulta caida debe salir 3; salio $rc:
$out"
[ "$(carril "$P3" M estado)" = "mergeado" ] || fail "(6) M debio reconciliarse"
[ "$(carril "$P3" N estado)" = "atorado" ] || fail "(6) N debia quedar como estaba"
[ "$(carril "$P3" N detenido_por)" = "esperando sello" ] \
  || fail "(6) el motivo de N debia sobrevivir a la consulta caida"
nevt=$(F="$P3" python3 -c "
import json, os
print(len(json.load(open(os.environ['F']))['eventos']))")
[ "$nevt" -eq 1 ] || fail "(6) esperaba un solo evento, hubo $nevt"
echo "ok (6): parcial cambia solo lo consultado y declara el unknown"

# (7) Forma y alcance: sin argumentos, archivo ausente o documento roto es de uso;
# un carril atorado por una razon que no es el sello NO se reconcilia, aunque el PR
# este MERGED: solo el sello es la causa obsoleta que este script retira.
out=$(corre); rc=$?
[ "$rc" -eq 2 ] || fail "(7) sin argumentos debe salir 2; salio $rc"
out=$(corre "$T/no-existe.json"); rc=$?
[ "$rc" -eq 2 ] || fail "(7) un archivo ausente debe salir 2; salio $rc"
P4="$T/roto.json"; printf '{"schema": "otro", "carriles": []}' >"$P4"
out=$(corre "$P4"); rc=$?
[ "$rc" -eq 2 ] || fail "(7) un documento fuera de contrato debe salir 2; salio $rc:
$out"
P5="$T/prueba-roja.json"; progreso "$P5"
sed -i.bak 's/esperando sello/prueba en rojo/g' "$P5" && rm -f "$P5.bak"
cp "$P5" "$P5.original"
out=$(corre "$P5"); rc=$?
[ "$rc" -eq 0 ] || fail "(7) un atorado por prueba roja no es unknown; salio $rc:
$out"
printf '%s' "$out" | grep -q "sin cambios" \
  || fail "(7) un atorado por prueba roja no debe reconciliarse:
$out"
cmp -s "$P5" "$P5.original" || fail "(7) el archivo cambio para un motivo que no es el sello"
echo "ok (7): uso y contrato salen 2, y un bloqueo real no se confunde con el sello"

echo "TODO VERDE: reconciliar-progreso"
