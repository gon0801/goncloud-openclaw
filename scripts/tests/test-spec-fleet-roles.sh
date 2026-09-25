#!/usr/bin/env bash
# 6.8: spec delta "Fleet roles and routing" — grep de las 4 reglas exactas
# y el enlace al mapa resuelve a un archivo existente.
set -u
cd "$(dirname "$0")/../.." || exit 1
SPEC=docs/spec/00-project-spec.md
fails=0
chk() { d=$1; shift; if "$@" >/dev/null 2>&1; then echo "OK: $d"; else echo "FALLO: $d"; fails=$((fails+1)); fi }
chk "spec existe" test -f "$SPEC"
chk "seccion Fleet roles and routing" grep -q "## Fleet roles and routing" "$SPEC"
chk "todos los agentes" grep -qF "Cualquier agente Claw o CLI puede mergear y desplegar sin autorización adicional por operación" "$SPEC"
chk "regla 4 (listo sin verify/ no se reporta)" grep -qF "Nada se reporta como \"listo\" sin haberse verificado antes con la prueba del repo" "$SPEC"
chk "D2 registrada" grep -qF "no se adapta el verifier a \`.cursor/skills/verify-*\`" "$SPEC"
chk "enlace al mapa 6.4" grep -qF "../runbooks/camino-feliz-producto.md" "$SPEC"
chk "enlace resuelve" test -f "docs/runbooks/camino-feliz-producto.md"
if [ $fails -gt 0 ]; then echo "ROJO: $fails fallo(s) en spec delta"; exit 1; fi
echo "VERDE: spec delta Fleet roles and routing cumple la DoD de 6.8"
