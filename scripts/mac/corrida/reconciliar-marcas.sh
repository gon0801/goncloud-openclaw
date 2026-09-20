#!/bin/bash
# Limpia solo marcas cuyo unico dueno conocido es una corrida cerrada.
# Una corrida abierta siempre gana; sesiones desconocidas se conservan.
corrida_reconciliar_marcas() {
  [ "$#" -eq 0 ] || { echo "uso: corrida.sh reconciliar-marcas" >&2; return 2; }
  [ -n "${TMUX_BIN:-}" ] || { echo "tmux no disponible" >&2; return 1; }

  local sesiones sesion marca dueno retiradas=0 conservadas=0 errores=0
  if ! sesiones="$("$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null)"; then
    echo "no se pudieron listar las sesiones tmux" >&2
    return 1
  fi

  while IFS= read -r sesion; do
    [ -n "$sesion" ] || continue
    marca="$("$TMUX_BIN" show-environment -t "=$sesion" OPENCLAW_WATCH 2>/dev/null || true)"
    [ "$marca" = "OPENCLAW_WATCH=1" ] || continue
    dueno="$(CORR_STATE="$CORRIDA_STATE" CORR_SESION="$sesion" python3 -c '
import glob, json, os
abierta = False
cerrada = False
for path in glob.glob(os.path.join(os.environ["CORR_STATE"], "*", "registro.json")):
    try:
        d = json.load(open(path))
    except Exception:
        continue
    nombres = [s.get("nombre") for s in d.get("sesiones", []) if isinstance(s, dict)]
    if os.environ["CORR_SESION"] not in nombres:
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
    if "$TMUX_BIN" set-environment -t "=$sesion" -u OPENCLAW_WATCH; then
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
  [ "$errores" -eq 0 ]
}
