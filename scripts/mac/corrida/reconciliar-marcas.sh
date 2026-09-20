#!/bin/bash
# Limpia solo marcas cuyo unico dueno conocido es una corrida cerrada.
# Una corrida abierta siempre gana; sesiones desconocidas se conservan.
corrida_reconciliar_marcas() {
  [ "$#" -eq 0 ] || { echo "uso: corrida.sh reconciliar-marcas" >&2; return 2; }
  [ -n "${TMUX_BIN:-}" ] || { echo "tmux no disponible" >&2; return 1; }
  marcas_lock_tomar || { echo "no se pudo tomar el lock global de marcas" >&2; return 1; }

  local sesiones sesion marca corrida_duena dueno retiradas=0 conservadas=0 errores=0
  if ! sesiones="$("$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null)"; then
    marcas_lock_soltar
    echo "no se pudieron listar las sesiones tmux" >&2
    return 1
  fi

  while IFS= read -r sesion; do
    [ -n "$sesion" ] || continue
    marcas_lock_refrescar
    marca="$("$TMUX_BIN" show-environment -t "=$sesion" OPENCLAW_WATCH 2>/dev/null || true)"
    [ "$marca" = "OPENCLAW_WATCH=1" ] || continue
    corrida_duena="$("$TMUX_BIN" show-environment -t "=$sesion" OPENCLAW_WATCH_RUN 2>/dev/null || true)"
    corrida_duena="${corrida_duena#OPENCLAW_WATCH_RUN=}"
    corrida_id_valido "$corrida_duena" || corrida_duena=""
    dueno="$(CORR_STATE="$CORRIDA_STATE" CORR_SESION="$sesion" CORR_RUN_ID="$corrida_duena" python3 -c '
import glob, json, os
abierta = False
cerrada = False
run_id = os.environ.get("CORR_RUN_ID", "")
paths = glob.glob(os.path.join(os.environ["CORR_STATE"], "*", "registro.json"))
for path in paths:
    try:
        d = json.load(open(path))
    except Exception:
        continue
    nombres = [s.get("nombre") for s in d.get("sesiones", []) if isinstance(s, dict)]
    registro_id = d.get("id") or os.path.basename(os.path.dirname(path))
    if os.environ["CORR_SESION"] not in nombres and registro_id != run_id:
        continue
    if d.get("estado") == "abierta":
        abierta = True
    elif d.get("estado") == "cerrada":
        cerrada = True
print("abierta" if abierta else "cerrada" if cerrada else "desconocida")
' 2>/dev/null)"
    [ -n "$dueno" ] || dueno="desconocida"
    if [ "$dueno" != "cerrada" ]; then
      conservadas=$((conservadas + 1))
      echo "marca conservada ($dueno): $sesion"
      continue
    fi
    marcas_lock_refrescar
    if "$TMUX_BIN" set-environment -t "=$sesion" -u OPENCLAW_WATCH; then
      "$TMUX_BIN" set-environment -t "=$sesion" -u OPENCLAW_WATCH_RUN 2>/dev/null || true
      retiradas=$((retiradas + 1))
      echo "marca retirada: $sesion"
    else
      errores=$((errores + 1))
      echo "no se pudo retirar OPENCLAW_WATCH de $sesion" >&2
    fi
  done <<EOF
$sesiones
EOF

  echo "reconciliacion: $retiradas retirada(s), $conservadas conservada(s), $errores error(es)"
  marcas_lock_soltar
  [ "$errores" -eq 0 ]
}
